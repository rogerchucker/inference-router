import asyncio
import logging
from dataclasses import dataclass
from typing import Literal, Protocol

from pydantic import BaseModel, Field

logger = logging.getLogger("uvicorn.error")

Task = Literal["simple", "writing", "coding", "reasoning"]


class InferenceRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=8192)
    max_tokens: int = Field(default=1024, ge=1, le=4096, strict=True)
    allow_cloud: bool = Field(default=False, strict=True)
    task: Task | Literal["auto"] = "auto"


class Usage(BaseModel):
    input_tokens: int = Field(ge=0, strict=True)
    output_tokens: int = Field(ge=0, strict=True)


class InferenceResponse(BaseModel):
    request_id: str
    provider: str
    model: str
    text: str
    usage: Usage | None
    estimated_cost_usd: float | None
    latency_ms: float
    attempts: int
    routing_reason: str


@dataclass(frozen=True)
class Completion:
    text: str
    usage: Usage | None = None


class ProviderError(Exception):
    def __init__(self, reason: str, *, retryable: bool = False):
        super().__init__(reason)
        self.reason = reason
        self.retryable = retryable


class Provider(Protocol):
    name: str
    model: str
    # Dollar rates per million input and output tokens.
    rates: tuple[float, float] | None

    async def complete(self, request: InferenceRequest) -> Completion: ...


class Classifier(Protocol):
    async def classify(self, prompt: str) -> tuple[Task, float]: ...


@dataclass(frozen=True)
class RoutingPolicy:
    local: Provider | None
    claude: Provider | None = None
    openai: Provider | None = None
    classifier: Classifier | None = None
    classifier_timeout: float = 2.0

    async def select(
        self, request: InferenceRequest, remaining: float
    ) -> tuple[tuple[Provider | None, ...], str]:
        if not request.allow_cloud:
            if self.local is None:
                raise InferenceFailed(422, "local_inference_unavailable")
            return (self.local,), "local_only"

        task, reason = await self.resolve_task(request, remaining)
        simple = (self.claude, self.openai) if self.local is None else (self.local, self.claude)
        candidates = {
            "simple": simple,
            "writing": (self.claude, self.openai),
            "coding": (self.openai, self.claude),
            "reasoning": (self.openai, self.claude),
        }
        return candidates[task], reason

    async def resolve_task(self, request: InferenceRequest, remaining: float) -> tuple[Task, str]:
        if request.task != "auto":
            return request.task, f"explicit_{request.task}"
        if self.classifier is None:
            return "simple", "classifier_unconfigured"
        try:
            async with asyncio.timeout(min(remaining, self.classifier_timeout)):
                task, confidence = await self.classifier.classify(request.prompt)
        except TimeoutError:
            return "simple", "classifier_timeout"
        except ProviderError:
            return "simple", "classifier_error"
        if confidence < 0.80:
            return "simple", "classifier_low_confidence"
        return task, f"classified_{task}"


class InferenceFailed(Exception):
    def __init__(self, status: int, code: str):
        super().__init__(code)
        self.status = status
        self.code = code


@dataclass(frozen=True)
class Router:
    primary: Provider | None
    backup: Provider | None
    total_timeout: float
    attempt_timeout: float
    policy: RoutingPolicy | None = None

    async def infer(self, request: InferenceRequest, request_id: str) -> InferenceResponse:
        clock = asyncio.get_running_loop().time
        started = clock()
        deadline = started + self.total_timeout
        candidates, reason = (self.primary, self.backup), "demo"
        if self.policy is not None:
            candidates, reason = await self.policy.select(request, deadline - clock())
        providers = [provider for provider in candidates if provider is not None]
        logger.info(
            "route_selected request_id=%s reason=%s candidates=%s",
            request_id, reason, ",".join(provider.name for provider in providers),
        )
        if not providers:
            raise InferenceFailed(503, "providers_unavailable")

        for attempt, provider in enumerate(providers, start=1):
            remaining = deadline - clock()
            if remaining <= 0:
                raise InferenceFailed(504, "deadline_exceeded")
            attempt_started = clock()
            try:
                async with asyncio.timeout(min(remaining, self.attempt_timeout)):
                    result = await provider.complete(request)
            except TimeoutError:
                outcome = "timeout"
            except ProviderError as error:
                outcome = error.reason
                if not error.retryable:
                    self.log_attempt(request_id, provider, attempt, outcome, clock() - attempt_started)
                    raise InferenceFailed(502, "provider_error") from error
            else:
                self.log_attempt(request_id, provider, attempt, "ok", clock() - attempt_started)
                cost = None
                if result.usage is not None and provider.rates is not None:
                    input_rate, output_rate = provider.rates
                    cost = (
                        result.usage.input_tokens * input_rate
                        + result.usage.output_tokens * output_rate
                    ) / 1_000_000
                return InferenceResponse(
                    request_id=request_id,
                    provider=provider.name,
                    model=provider.model,
                    text=result.text,
                    usage=result.usage,
                    estimated_cost_usd=cost,
                    latency_ms=round((clock() - started) * 1000, 2),
                    attempts=attempt,
                    routing_reason=reason,
                )
            self.log_attempt(request_id, provider, attempt, outcome, clock() - attempt_started)

        if outcome == "timeout" or clock() >= deadline:
            raise InferenceFailed(504, "deadline_exceeded")
        raise InferenceFailed(503, "providers_unavailable")

    @staticmethod
    def log_attempt(
        request_id: str, provider: Provider, attempt: int, outcome: str, seconds: float
    ) -> None:
        logger.info(
            "provider_attempt request_id=%s provider=%s model=%s attempt=%d outcome=%s duration_ms=%.2f",
            request_id, provider.name, provider.model, attempt, outcome, seconds * 1000,
        )
