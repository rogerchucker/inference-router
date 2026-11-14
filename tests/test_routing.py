import asyncio
import json
import os
import unittest
from unittest.mock import patch

import httpx

from app import configure_router
from router import InferenceFailed, InferenceRequest


class RoutingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.environment = {
            "OPENAI_API_KEY": "fake-openai",
            "ANTHROPIC_API_KEY": "fake-claude",
            "OPENROUTER_API_KEY": "fake-openrouter",
        }
        self.requests = []
        self.responses = {}
        self.delay_host = None
        self.client = httpx.AsyncClient(transport=httpx.MockTransport(self.respond))
        self.addAsyncCleanup(self.client.aclose)

    async def respond(self, request):
        self.requests.append(request)
        host = request.url.host
        if host == self.delay_host:
            await asyncio.sleep(60)
        if host in self.responses:
            return self.responses[host]
        if host == "api.anthropic.com":
            return httpx.Response(200, json={
                "content": [
                    {"type": "thinking", "thinking": "omit"},
                    {"type": "text", "text": "Claude response"},
                ],
                "usage": {"input_tokens": 11, "output_tokens": 3},
            })
        self.assertIn(host, {"api.openai.com", "127.0.0.1"})
        return httpx.Response(200, json={
            "choices": [{"message": {"content": "Response"}}],
            "usage": {"prompt_tokens": 9, "completion_tokens": 2},
        })

    async def infer(self, **fields):
        with patch.dict(os.environ, self.environment, clear=True):
            router = configure_router(self.client)
        return await router.infer(InferenceRequest(prompt="Example prompt", **fields), "req")

    def hosts(self):
        return [request.url.host for request in self.requests]

    def jev_response(self, choice, confidence):
        self.responses["openrouter.ai"] = httpx.Response(200, json={
            "answers": {"task": {"type": "choice", "choice": choice, "confidence": confidence}},
        })

    async def test_local_only_blocks_cloud_even_when_ollama_fails(self):
        result = await self.infer()
        self.assertEqual((result.provider, result.model, result.routing_reason),
                         ("ollama", "qwen3.5:4b", "local_only"))
        self.assertNotIn("Authorization", self.requests[0].headers)
        self.requests.clear()
        self.responses["127.0.0.1"] = httpx.Response(503)
        with self.assertRaises(InferenceFailed) as context:
            await self.infer(task="coding", allow_cloud=False)
        self.assertEqual(context.exception.status, 503)
        self.assertEqual(self.hosts(), ["127.0.0.1"])

    async def test_explicit_tasks_skip_jev(self):
        for task, provider, host in [
            ("simple", "ollama", "127.0.0.1"),
            ("writing", "claude", "api.anthropic.com"),
            ("coding", "openai", "api.openai.com"),
            ("reasoning", "openai", "api.openai.com"),
        ]:
            with self.subTest(task=task):
                self.requests.clear()
                result = await self.infer(task=task, allow_cloud=True)
                self.assertEqual((result.provider, result.routing_reason), (provider, f"explicit_{task}"))
                self.assertEqual(self.hosts(), [host])

    async def test_jev_classifies_auto_and_claude_returns_text(self):
        self.jev_response("writing", 0.80)
        result = await self.infer(allow_cloud=True)
        jev, claude = self.requests
        self.assertEqual(self.hosts(), ["openrouter.ai", "api.anthropic.com"])
        self.assertEqual(jev.url.path, "/api/alpha/decisions")
        self.assertEqual(jev.headers["authorization"], "Bearer fake-openrouter")
        self.assertEqual(json.loads(jev.content)["model"], "typesafe/jev-1.14")
        self.assertEqual(json.loads(jev.content)["state"], "Example prompt")
        self.assertEqual(claude.url.path, "/v1/messages")
        self.assertEqual(claude.headers["x-api-key"], "fake-claude")
        self.assertEqual(json.loads(claude.content)["model"], "claude-opus-5-5")
        self.assertEqual((result.text, result.usage.input_tokens), ("Claude response", 11))
        self.assertEqual((result.routing_reason, result.attempts), ("classified_writing", 1))

    async def test_jev_low_confidence_invalid_response_and_error_use_ollama(self):
        for choice, confidence, reason in [
            ("reasoning", 0.79, "classifier_low_confidence"),
            ("unknown", 1, "classifier_error"),
            ("coding", 2, "classifier_error"),
            (None, None, "classifier_error"),
        ]:
            with self.subTest(choice=choice, confidence=confidence):
                self.requests.clear()
                if choice is None:
                    self.responses["openrouter.ai"] = httpx.Response(503)
                else:
                    self.jev_response(choice, confidence)
                result = await self.infer(allow_cloud=True)
                self.assertEqual(self.hosts(), ["openrouter.ai", "127.0.0.1"])
                self.assertEqual((result.provider, result.routing_reason), ("ollama", reason))

    async def test_jev_timeout_uses_ollama_and_shares_request_deadline(self):
        self.delay_host = "openrouter.ai"
        self.environment["CLASSIFIER_TIMEOUT_SECONDS"] = "0.01"
        result = await self.infer(allow_cloud=True)
        self.assertEqual((result.provider, result.routing_reason), ("ollama", "classifier_timeout"))
        self.requests.clear()
        self.environment.update(CLASSIFIER_TIMEOUT_SECONDS="2", ROUTER_TIMEOUT_SECONDS="0.01")
        with self.assertRaises(InferenceFailed) as context:
            await self.infer(allow_cloud=True)
        self.assertEqual(context.exception.status, 504)
        self.assertEqual(self.hosts(), ["openrouter.ai"])

    async def test_openai_rate_limit_falls_back_to_claude(self):
        self.responses["api.openai.com"] = httpx.Response(429)
        result = await self.infer(task="coding", allow_cloud=True, max_tokens=512)
        self.assertEqual((result.provider, result.attempts), ("claude", 2))
        self.assertEqual(self.hosts(), ["api.openai.com", "api.anthropic.com"])
        request = self.requests[0]
        self.assertEqual(request.url.path, "/v1/chat/completions")
        self.assertEqual(request.headers["authorization"], "Bearer fake-openai")
        self.assertEqual(json.loads(request.content)["max_completion_tokens"], 512)
        self.assertEqual(json.loads(request.content)["model"], "gpt-6-astra")

    async def test_openai_timeout_only_falls_back_with_remaining_budget(self):
        self.delay_host = "api.openai.com"
        self.environment["PROVIDER_TIMEOUT_SECONDS"] = "0.01"
        result = await self.infer(task="coding", allow_cloud=True)
        self.assertEqual((result.provider, result.attempts), ("claude", 2))
        self.requests.clear()
        self.environment.update(ROUTER_TIMEOUT_SECONDS="0.01", PROVIDER_TIMEOUT_SECONDS="1")
        with self.assertRaises(InferenceFailed) as context:
            await self.infer(task="coding", allow_cloud=True)
        self.assertEqual(context.exception.status, 504)
        self.assertEqual(self.hosts(), ["api.openai.com"])

    async def test_permanent_error_stops_fallback(self):
        self.responses["api.anthropic.com"] = httpx.Response(401)
        with self.assertRaises(InferenceFailed) as context:
            await self.infer(task="writing", allow_cloud=True)
        self.assertEqual(context.exception.status, 502)
        self.assertEqual(self.hosts(), ["api.anthropic.com"])

    async def test_ollama_failure_can_use_claude_with_cloud_opt_in(self):
        self.responses["127.0.0.1"] = httpx.Response(503)
        result = await self.infer(task="simple", allow_cloud=True)
        self.assertEqual((result.provider, result.attempts), ("claude", 2))
        self.assertEqual(self.hosts(), ["127.0.0.1", "api.anthropic.com"])

    async def test_writing_can_fall_back_to_openai(self):
        self.responses["api.anthropic.com"] = httpx.Response(529)
        result = await self.infer(task="writing", allow_cloud=True)
        self.assertEqual((result.provider, result.attempts), ("openai", 2))
        self.assertEqual(self.hosts(), ["api.anthropic.com", "api.openai.com"])

    async def test_missing_keys_skip_unconfigured_providers(self):
        del self.environment["OPENROUTER_API_KEY"]
        del self.environment["OPENAI_API_KEY"]
        result = await self.infer(task="coding", allow_cloud=True)
        self.assertEqual((result.provider, result.attempts), ("claude", 1))
        result = await self.infer(allow_cloud=True)
        self.assertEqual((result.provider, result.routing_reason), ("ollama", "classifier_unconfigured"))
        self.assertEqual(self.hosts(), ["api.anthropic.com", "127.0.0.1"])
        del self.environment["ANTHROPIC_API_KEY"]
        with self.assertRaises(InferenceFailed) as context:
            await self.infer(task="writing", allow_cloud=True)
        self.assertEqual(context.exception.status, 503)

    async def test_rejects_remote_ollama_url(self):
        self.environment["MODEL_BASE_URL"] = "https://example.com/v1"
        with self.assertRaisesRegex(ValueError, "loopback"):
            await self.infer()
        self.assertEqual(self.hosts(), [])

    async def test_eks_rejects_demo_and_ollama_configuration(self):
        for name, value in (("DEMO_PRIMARY_FAULT", "none"), ("MODEL_BASE_URL", "")):
            with self.subTest(name=name), patch.dict(os.environ, {
                "ROUTER_MODE": "eks",
                name: value,
            }, clear=True), self.assertRaisesRegex(ValueError, "ROUTER_MODE=eks"):
                configure_router(self.client)
        self.assertEqual(self.hosts(), [])

    async def test_rejects_unknown_router_mode(self):
        with (
            patch.dict(os.environ, {"ROUTER_MODE": "ekz"}, clear=True),
            self.assertRaisesRegex(ValueError, "ROUTER_MODE must be local or eks"),
        ):
            configure_router(self.client)
        self.assertEqual(self.hosts(), [])

    async def test_eks_routes_cloud_tasks_without_ollama(self):
        self.environment["ROUTER_MODE"] = "eks"
        for task, provider, host in [
            ("simple", "claude", "api.anthropic.com"),
            ("writing", "claude", "api.anthropic.com"),
            ("coding", "openai", "api.openai.com"),
            ("reasoning", "openai", "api.openai.com"),
        ]:
            with self.subTest(task=task):
                self.requests.clear()
                result = await self.infer(allow_cloud=True, task=task)
                self.assertEqual((result.provider, self.hosts()), (provider, [host]))

    async def test_eks_auto_uses_cloud_fallback_with_low_confidence(self):
        self.environment["ROUTER_MODE"] = "eks"
        self.jev_response("coding", 0.79)
        self.responses["api.anthropic.com"] = httpx.Response(429)
        result = await self.infer(allow_cloud=True)
        self.assertEqual((result.provider, result.attempts), ("openai", 2))
        self.assertEqual(result.routing_reason, "classifier_low_confidence")
        self.assertEqual(self.hosts(), ["openrouter.ai", "api.anthropic.com", "api.openai.com"])

    async def test_eks_with_no_generators_returns_503(self):
        self.environment = {"ROUTER_MODE": "eks"}
        with self.assertRaises(InferenceFailed) as context:
            await self.infer(allow_cloud=True)
        self.assertEqual(context.exception.status, 503)
        self.assertEqual(context.exception.code, "providers_unavailable")
        self.assertEqual(self.hosts(), [])
