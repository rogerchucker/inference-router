import asyncio
import json
import os
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

import httpx

from app import app, configure_router
from providers import ChatProvider, DemoProvider
from router import InferenceFailed, InferenceRequest, Router


@asynccontextmanager
async def api_client(environment=None):
    with patch.dict(os.environ, environment or {}, clear=True):
        async with app.router.lifespan_context(app):
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://router.test"
            ) as client:
                yield client


class APITests(unittest.IsolatedAsyncioTestCase):
    async def test_happy_path_and_probes(self):
        async with api_client({"DEMO_PRIMARY_FAULT": "none"}) as client:
            self.assertEqual((await client.get("/livez")).status_code, 200)
            self.assertEqual((await client.get("/readyz")).status_code, 200)
            response = await client.post("/v1/infer", json={"prompt": "Hello world"})
        self.assertEqual(response.status_code, 200)
        result = response.json()
        self.assertEqual((result["provider"], result["attempts"]), ("primary", 1))
        self.assertEqual(result["usage"]["input_tokens"], 2)
        self.assertAlmostEqual(result["estimated_cost_usd"], 0.0000014)
        self.assertTrue(result["request_id"])

    async def test_rejects_invalid_request_without_reflecting_prompt(self):
        async with api_client() as client:
            response = await client.post("/v1/infer", json={"prompt": "private", "max_tokens": True})
        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json(), {"detail": "invalid_request"})

    async def test_fallback_and_permanent_error(self):
        for fault, expected in (("unavailable", 200), ("rejected", 502)):
            with self.subTest(fault=fault):
                async with api_client({"DEMO_PRIMARY_FAULT": fault}) as client:
                    response = await client.post("/v1/infer", json={"prompt": "hello"})
                    self.assertEqual((await client.get("/readyz")).status_code, 200)
                self.assertEqual(response.status_code, expected)
                if expected == 200:
                    self.assertEqual(response.json()["provider"], "backup")
                    self.assertEqual(response.json()["attempts"], 2)
                else:
                    self.assertTrue(response.headers["X-Request-ID"])


class RouterTests(unittest.IsolatedAsyncioTestCase):
    async def test_attempt_timeout_leaves_time_for_fallback(self):
        router = Router(
            DemoProvider("primary", "demo", (0, 0), "timeout"),
            DemoProvider("backup", "demo", (0, 0)),
            total_timeout=1,
            attempt_timeout=0.01,
        )
        result = await router.infer(InferenceRequest(prompt="hello"), "req")
        self.assertEqual((result.provider, result.attempts), ("backup", 2))

    async def test_total_deadline_prevents_fallback(self):
        router = Router(
            DemoProvider("primary", "demo", (0, 0), "timeout"),
            DemoProvider("backup", "demo", (0, 0)),
            total_timeout=0.01,
            attempt_timeout=1,
        )
        with self.assertRaises(InferenceFailed) as context:
            await router.infer(InferenceRequest(prompt="hello"), "req")
        self.assertEqual(context.exception.status, 504)

    async def test_two_transient_failures_return_503(self):
        router = Router(
            DemoProvider("primary", "demo", (0, 0), "unavailable"),
            DemoProvider("backup", "demo", (0, 0), "unavailable"),
            total_timeout=1,
            attempt_timeout=0.5,
        )
        with self.assertRaises(InferenceFailed) as context:
            await router.infer(InferenceRequest(prompt="hello"), "req")
        self.assertEqual(context.exception.status, 503)

    async def test_cancellation_propagates(self):
        router = Router(
            DemoProvider("primary", "demo", (0, 0), "timeout"),
            DemoProvider("backup", "demo", (0, 0)),
            total_timeout=1,
            attempt_timeout=0.5,
        )
        task = asyncio.create_task(router.infer(InferenceRequest(prompt="hello"), "req"))
        await asyncio.sleep(0)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task

    async def test_bad_upstream_response_is_permanent(self):
        transport = httpx.MockTransport(lambda _: httpx.Response(200, json={"choices": []}))
        async with httpx.AsyncClient(transport=transport) as client:
            router = Router(
                ChatProvider("primary", "demo", "http://provider.test/v1/chat/completions", client),
                DemoProvider("backup", "demo", (0, 0)),
                total_timeout=1,
                attempt_timeout=0.5,
            )
            with self.assertRaises(InferenceFailed) as context:
                await router.infer(InferenceRequest(prompt="hello"), "req")
        self.assertEqual(context.exception.status, 502)

    async def test_reasoning_can_be_disabled_and_empty_text_is_rejected(self):
        bodies = []

        def respond(request):
            body = json.loads(request.content)
            bodies.append(body)
            text = "Hello." if body.get("reasoning_effort") == "none" else ""
            return httpx.Response(200, json={"choices": [{"message": {"content": text}}]})

        with patch.dict(os.environ, {"MODEL_REASONING_EFFORT": ""}, clear=True):
            async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
                request = InferenceRequest(prompt="hello")
                with self.assertRaises(InferenceFailed) as context:
                    await configure_router(client).infer(request, "req")
                self.assertEqual(context.exception.status, 502)
                with patch.dict(os.environ, {"MODEL_REASONING_EFFORT": "none"}):
                    result = await configure_router(client).infer(request, "req")
        self.assertEqual(result.text, "Hello.")
        self.assertNotIn("reasoning_effort", bodies[0])
        self.assertEqual(len(bodies), 2)
