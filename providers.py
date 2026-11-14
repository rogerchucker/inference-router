import asyncio
from dataclasses import dataclass, field
from typing import Literal

import httpx
from pydantic import BaseModel, Field, ValidationError

from router import Completion, InferenceRequest, ProviderError, Task, Usage


@dataclass(frozen=True)
class DemoProvider:
    name: str
    model: str
    rates: tuple[float, float]
    fault: str = "none"

    async def complete(self, request: InferenceRequest) -> Completion:
        if self.fault == "timeout":
            await asyncio.sleep(60)
        if self.fault == "unavailable":
            raise ProviderError("unavailable", retryable=True)
        if self.fault == "rejected":
            raise ProviderError("rejected")
        text = f"Demo response from {self.model}"
        return Completion(
            text=text,
            usage=Usage(
                input_tokens=len(request.prompt.split()),
                output_tokens=len(text.split()),
            ),
        )


class ChatMessage(BaseModel):
    content: str

    @property
    def text(self) -> str:
        if not self.content.strip():
            raise ProviderError("empty_completion")
        return self.content


class ChatChoice(BaseModel):
    message: ChatMessage


class ChatUsage(BaseModel):
    prompt_tokens: int = Field(ge=0, strict=True)
    completion_tokens: int = Field(ge=0, strict=True)


class ChatCompletion(BaseModel):
    choices: list[ChatChoice]
    usage: ChatUsage | None = None


async def post_json(
    client: httpx.AsyncClient, url: str, payload: dict, headers: dict[str, str] | None = None
) -> bytes:
    try:
        response = await client.post(url, json=payload, headers=headers)
    except httpx.TransportError as error:
        raise ProviderError("transport_error", retryable=True) from error

    status = response.status_code
    if not response.is_success:
        raise ProviderError(f"http_{status}", retryable=status == 429 or status >= 500)
    return response.content


@dataclass(frozen=True)
class ChatProvider:
    name: str
    model: str
    url: str
    client: httpx.AsyncClient
    reasoning_effort: str | None = None
    rates: tuple[float, float] | None = None
    api_key: str | None = field(default=None, repr=False)
    token_limit_field: str = "max_tokens"

    async def complete(self, request: InferenceRequest) -> Completion:
        payload = {
            "model": self.model,
            "messages": [{"role": "user", "content": request.prompt}],
            self.token_limit_field: request.max_tokens,
            "stream": False,
        }
        if self.reasoning_effort:
            payload["reasoning_effort"] = self.reasoning_effort
        headers = {"Authorization": f"Bearer {self.api_key}"} if self.api_key else None
        body = await post_json(self.client, self.url, payload, headers)

        try:
            result = ChatCompletion.model_validate_json(body)
            usage = (
                Usage(input_tokens=result.usage.prompt_tokens, output_tokens=result.usage.completion_tokens)
                if result.usage is not None else None
            )
            return Completion(result.choices[0].message.text, usage)
        except (ValidationError, IndexError) as error:
            raise ProviderError("invalid_response") from error


class ClaudeBlock(BaseModel):
    type: str
    text: str | None = None


class ClaudeMessage(BaseModel):
    content: list[ClaudeBlock]
    usage: Usage


@dataclass(frozen=True)
class ClaudeProvider:
    client: httpx.AsyncClient
    api_key: str = field(repr=False)
    name: str = "claude"
    model: str = "claude-opus-5-5"
    rates: tuple[float, float] | None = None

    async def complete(self, request: InferenceRequest) -> Completion:
        body = await post_json(
            self.client,
            "https://api.anthropic.com/v1/messages",
            {
                "model": self.model,
                "messages": [{"role": "user", "content": request.prompt}],
                "max_tokens": request.max_tokens,
                "output_config": {"effort": "low"},
            },
            {"x-api-key": self.api_key, "anthropic-version": "2023-06-01"},
        )
        try:
            message = ClaudeMessage.model_validate_json(body)
        except ValidationError as error:
            raise ProviderError("invalid_response") from error
        text = "".join(block.text or "" for block in message.content if block.type == "text")
        if not text.strip():
            raise ProviderError("empty_completion")
        return Completion(text, message.usage)


class JevChoice(BaseModel):
    type: Literal["choice"]
    choice: Task
    confidence: float = Field(ge=0, le=1, strict=True)


class JevDecision(BaseModel):
    answers: dict[str, JevChoice]


@dataclass(frozen=True)
class JevClassifier:
    client: httpx.AsyncClient
    api_key: str = field(repr=False)

    async def classify(self, prompt: str) -> tuple[Task, float]:
        body = await post_json(
            self.client,
            "https://openrouter.ai/api/alpha/decisions",
            {
                "model": "typesafe/jev-1.14",
                "state": prompt,
                "questions": {
                    "task": {
                        "type": "choice",
                        "instructions": "Classify the work the user requests.",
                        "criteria": {
                            "simple": "Basic Q&A, short summaries, and simple rewrites",
                            "writing": "Drafting or substantially editing longer prose",
                            "coding": "Writing, reviewing, testing, or debugging code",
                            "reasoning": "Multistep analysis, planning, or problem solving",
                        },
                    }
                },
            },
            {"Authorization": f"Bearer {self.api_key}"},
        )
        try:
            answer = JevDecision.model_validate_json(body).answers["task"]
        except (ValidationError, KeyError) as error:
            raise ProviderError("invalid_response") from error
        return answer.choice, answer.confidence
