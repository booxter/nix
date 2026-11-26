from __future__ import annotations

from pydantic import BaseModel, FiniteFloat, ValidationError

from .usage import MetadataValue


class TokenDetails(BaseModel):
    cached_tokens: int | None = None
    reasoning_tokens: int | None = None


class CostDetails(BaseModel):
    upstream_inference_cost: FiniteFloat | None = None
    upstream_inference_prompt_cost: FiniteFloat | None = None
    upstream_inference_completions_cost: FiniteFloat | None = None


class Usage(BaseModel):
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    cost: FiniteFloat | None = None
    is_byok: bool | None = None
    prompt_tokens_details: TokenDetails | None = None
    completion_tokens_details: TokenDetails | None = None
    cost_details: CostDetails | None = None


class Choice(BaseModel):
    finish_reason: str | None = None


class ResponseUsage(BaseModel):
    id: str | None = None
    model: str | None = None
    provider: str | None = None
    system_fingerprint: str | None = None
    choices: list[Choice] = []
    usage: Usage | None = None


def response_metadata(data: bytes, request_id: str | None) -> dict[str, MetadataValue]:
    metadata: dict[str, MetadataValue] = {}
    if request_id is not None:
        metadata["request_id"] = request_id
    try:
        response = ResponseUsage.model_validate_json(data)
    except ValidationError:
        # Accounting must not turn an otherwise usable decision into a failure.
        metadata["usage_unavailable"] = True
        return metadata

    values: dict[str, MetadataValue] = {
        "generation_id": response.id,
        "model": response.model,
        "provider": response.provider,
        "system_fingerprint": response.system_fingerprint,
        "finish_reason": response.choices[0].finish_reason if response.choices else None,
    }
    usage = response.usage
    if usage is not None:
        values.update(
            prompt_tokens=usage.prompt_tokens,
            completion_tokens=usage.completion_tokens,
            total_tokens=usage.total_tokens,
            cost=usage.cost,
            is_byok=usage.is_byok,
        )
        if usage.prompt_tokens_details is not None:
            values["cached_tokens"] = usage.prompt_tokens_details.cached_tokens
        if usage.completion_tokens_details is not None:
            values["reasoning_tokens"] = usage.completion_tokens_details.reasoning_tokens
        if usage.cost_details is not None:
            values.update(
                upstream_inference_cost=usage.cost_details.upstream_inference_cost,
                upstream_inference_prompt_cost=usage.cost_details.upstream_inference_prompt_cost,
                upstream_inference_completions_cost=usage.cost_details.upstream_inference_completions_cost,
            )
    metadata.update({name: value for name, value in values.items() if value is not None})
    return metadata
