from dataclasses import dataclass
from typing import Final, Literal, Protocol

from openai import OpenAI, OpenAIError

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.usage import PersonalUsageService, UsageWindow

RESPONSES_ENDPOINT: Final = "https://chatgpt.com/backend-api/codex/responses"


def _needs_warmup(window: UsageWindow | None) -> bool:
    return (
        window is not None
        and window.limit_window_seconds is not None
        and window.reset_after_seconds is not None
        and window.reset_after_seconds <= 0
    )


@dataclass(frozen=True)
class WarmupRequest:
    model: str = "gpt-5.4-mini"
    instructions: str = "Reply with exactly OK."
    prompt: str = "OK"
    reasoning_effort: Literal["low"] = "low"
    verbosity: Literal["low"] = "low"


class ResponsesClient(Protocol):
    def stream_event_types(
        self,
        auth: CodexAuth,
        *,
        endpoint: str,
        request: WarmupRequest,
    ) -> tuple[str, ...]: ...


@dataclass(frozen=True)
class OpenAIResponsesClient:
    timeout_seconds: float = 30.0

    def stream_event_types(
        self,
        auth: CodexAuth,
        *,
        endpoint: str,
        request: WarmupRequest,
    ) -> tuple[str, ...]:
        suffix = "/responses"
        if not endpoint.endswith(suffix):
            raise CodexToolsError(f"Codex Responses endpoint must end with {suffix}: {endpoint}")
        if not auth.account_id:
            raise CodexToolsError("Codex account ID is required to start the usage window")

        try:
            with OpenAI(
                api_key=auth.access_token,
                base_url=endpoint.removesuffix(suffix),
                default_headers={"ChatGPT-Account-ID": auth.account_id},
                timeout=self.timeout_seconds,
            ) as client:
                stream = client.responses.create(
                    model=request.model,
                    instructions=request.instructions,
                    input=request.prompt,
                    reasoning={"effort": request.reasoning_effort},
                    store=False,
                    stream=True,
                    text={"verbosity": request.verbosity},
                )
                return tuple(event.type for event in stream)
        except OpenAIError as error:
            raise CodexToolsError(f"Codex warm-up request failed: {error}") from error


@dataclass(frozen=True)
class WarmerService:
    usage_service: PersonalUsageService
    responses_client: ResponsesClient
    responses_endpoint: str = RESPONSES_ENDPOINT

    def warm_if_needed(self, auth: CodexAuth, *, now: float) -> bool:
        usage = self.usage_service.fetch(auth, now=now)
        if not any(_needs_warmup(window) for window in (usage.five_hour, usage.weekly)):
            return False
        if not auth.account_id:
            raise CodexToolsError("Codex account ID is required to start the usage window")

        event_types = self.responses_client.stream_event_types(
            auth,
            endpoint=self.responses_endpoint,
            request=WarmupRequest(),
        )
        if "response.completed" not in event_types:
            raise CodexToolsError("Codex warm-up request did not complete")
        return True
