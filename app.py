import logging
import math
import os
from contextlib import asynccontextmanager
from uuid import uuid4

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from providers import ChatProvider, ClaudeProvider, DemoProvider, JevClassifier
from router import (
    InferenceFailed,
    InferenceRequest,
    InferenceResponse,
    Router,
    RoutingPolicy,
)

logger = logging.getLogger("uvicorn.error")


def timeout_setting(name: str, default: str) -> float:
    seconds = float(os.getenv(name, default))
    if not math.isfinite(seconds) or seconds <= 0:
        raise ValueError(f"{name} must be a finite positive number")
    return seconds


def ollama_url() -> str:
    url = httpx.URL(os.getenv("MODEL_BASE_URL", "http://127.0.0.1:11434/v1"))
    loopback = {"localhost", "127.0.0.1", "::1"}
    if (url.scheme not in {"http", "https"} or url.host not in loopback
            or url.userinfo or url.query or url.fragment):
        raise ValueError("MODEL_BASE_URL must be a loopback HTTP(S) URL without credentials, query, or fragment")
    return str(url).rstrip("/") + "/chat/completions"


def configure_router(client: httpx.AsyncClient) -> Router:
    mode = os.getenv("ROUTER_MODE", "local")
    if mode not in {"local", "eks"}:
        raise ValueError("ROUTER_MODE must be local or eks")

    fault = os.getenv("DEMO_PRIMARY_FAULT")
    if mode == "eks" and (fault is not None or "MODEL_BASE_URL" in os.environ):
        raise ValueError("ROUTER_MODE=eks excludes DEMO_PRIMARY_FAULT and MODEL_BASE_URL")

    if fault is not None:
        if fault not in {"none", "unavailable", "timeout", "rejected"}:
            raise ValueError("DEMO_PRIMARY_FAULT must be none, unavailable, timeout, or rejected")
        primary = DemoProvider("primary", "demo-fast", (0.10, 0.30), fault)
        backup = DemoProvider("backup", "demo-backup", (0.20, 0.60))
        return Router(
            primary, backup,
            total_timeout=timeout_setting("ROUTER_TIMEOUT_SECONDS", "2.0"),
            attempt_timeout=timeout_setting("PROVIDER_TIMEOUT_SECONDS", "0.75"),
        )

    local = None
    if mode == "local":
        local = ChatProvider(
            "ollama", "qwen3.5:4b", ollama_url(), client,
            reasoning_effort=os.getenv("MODEL_REASONING_EFFORT", "none"),
        )
    openai_key = os.getenv("OPENAI_API_KEY")
    anthropic_key = os.getenv("ANTHROPIC_API_KEY")
    openrouter_key = os.getenv("OPENROUTER_API_KEY")
    openai = (
        ChatProvider(
            "openai", "gpt-6-astra", "https://api.openai.com/v1/chat/completions", client,
            reasoning_effort="low", api_key=openai_key, token_limit_field="max_completion_tokens",
        ) if openai_key else None
    )
    policy = RoutingPolicy(
        local=local,
        claude=ClaudeProvider(client, anthropic_key) if anthropic_key else None,
        openai=openai,
        classifier=JevClassifier(client, openrouter_key) if openrouter_key else None,
        classifier_timeout=timeout_setting("CLASSIFIER_TIMEOUT_SECONDS", "2.0"),
    )
    return Router(
        None, None,
        total_timeout=timeout_setting("ROUTER_TIMEOUT_SECONDS", "60.0"),
        attempt_timeout=timeout_setting("PROVIDER_TIMEOUT_SECONDS", "25.0"),
        policy=policy,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with httpx.AsyncClient(timeout=None, trust_env=False) as client:
        app.state.router = configure_router(client)
        yield


app = FastAPI(title="Interview model router", lifespan=lifespan)


@app.exception_handler(RequestValidationError)
async def invalid_request(_request: Request, _error: RequestValidationError) -> JSONResponse:
    return JSONResponse(status_code=422, content={"detail": "invalid_request"})


@app.get("/livez")
async def live() -> dict[str, str]:
    return {"status": "live"}


@app.get("/readyz")
async def ready(request: Request) -> dict[str, str]:
    if not hasattr(request.app.state, "router"):
        raise HTTPException(503, detail="initializing")
    return {"status": "ready"}


@app.post("/v1/infer")
async def infer(payload: InferenceRequest, request: Request) -> InferenceResponse:
    request_id = uuid4().hex
    try:
        return await request.app.state.router.infer(payload, request_id)
    except InferenceFailed as error:
        logger.info("inference_failed request_id=%s code=%s", request_id, error.code)
        raise HTTPException(error.status, detail=error.code, headers={"X-Request-ID": request_id}) from error
