import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, Self, cast

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    SecretStr,
    TypeAdapter,
    ValidationError,
    field_validator,
)


class Error(RuntimeError):
    pass


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    base_url: str = Field(min_length=1)
    api_token: SecretStr
    auto_tag: str = Field(min_length=1)
    auto_ocr_tag: str = Field(min_length=1)
    ocr_complete_tag: str = Field(min_length=1)
    auto_ocr_workflow_name: str = Field(min_length=1)
    post_ocr_workflow_name: str = Field(min_length=1)
    wait_seconds: float = Field(default=120, gt=0)
    poll_seconds: float = Field(default=2, gt=0)

    @field_validator("base_url")
    @classmethod
    def validate_base_url(cls, value: str) -> str:
        normalized = value.rstrip("/")
        parsed = urllib.parse.urlparse(normalized)
        if parsed.scheme not in {"http", "https"} or parsed.netloc == "":
            raise ValueError("base_url must be an HTTP(S) URL")
        return normalized

    @classmethod
    def from_environment(cls, environment: Mapping[str, str] | None = None) -> Self:
        values = os.environ if environment is None else environment
        try:
            token = Path(values["PAPERLESS_API_TOKEN_FILE"]).read_text(encoding="utf-8").strip()
            return cls(
                base_url=values["PAPERLESS_BASE_URL"],
                api_token=SecretStr(token),
                auto_tag=values["PAPERLESS_GPT_AUTO_TAG"],
                auto_ocr_tag=values["PAPERLESS_GPT_AUTO_OCR_TAG"],
                ocr_complete_tag=values["PAPERLESS_GPT_OCR_COMPLETE_TAG"],
                auto_ocr_workflow_name=values["PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME"],
                post_ocr_workflow_name=values["PAPERLESS_GPT_POST_OCR_WORKFLOW_NAME"],
                wait_seconds=float(values.get("PAPERLESS_GPT_WAIT_SECONDS", "120")),
                poll_seconds=float(values.get("PAPERLESS_GPT_POLL_SECONDS", "2")),
            )
        except (KeyError, OSError, ValidationError, ValueError) as exc:
            raise Error(f"invalid Paperless configuration: {exc}") from exc


class Tag(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    id: int
    name: str


class WorkflowComponent(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    type: int
    id: int | None = None
    assign_tags: list[int] | None = None
    remove_tags: list[int] | None = None
    filter_has_tags: list[int] | None = None
    filter_has_not_tags: list[int] | None = None


class Workflow(BaseModel):
    model_config = ConfigDict(extra="allow", frozen=True, strict=True)

    id: int
    name: str
    triggers: list[WorkflowComponent] = Field(default_factory=list)
    actions: list[WorkflowComponent] = Field(default_factory=list)


class TagPayload(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    name: str
    matching_algorithm: int = 0
    is_inbox_tag: bool = False


class WorkflowPayload(BaseModel):
    model_config = ConfigDict(frozen=True, strict=True)

    name: str
    order: int = 0
    enabled: bool = True
    triggers: list[WorkflowComponent]
    actions: list[WorkflowComponent]


TAGS: TypeAdapter[list[Tag]] = TypeAdapter(list[Tag])
WORKFLOWS: TypeAdapter[list[Workflow]] = TypeAdapter(list[Workflow])


@dataclass(frozen=True)
class DesiredWorkflow:
    name: str
    triggers: tuple[WorkflowComponent, ...]
    actions: tuple[WorkflowComponent, ...]


class HttpTransport(Protocol):
    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        payload: object | None = None,
    ) -> object | None: ...


class Waiter(Protocol):
    def monotonic(self) -> float: ...

    def sleep(self, seconds: float) -> None: ...


@dataclass(frozen=True)
class SystemWaiter:
    def monotonic(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


@dataclass(frozen=True)
class UrllibTransport:
    timeout: float = 10

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        payload: object | None = None,
    ) -> object | None:
        request = urllib.request.Request(
            url,
            data=None if payload is None else json.dumps(payload).encode("utf-8"),
            method=method,
            headers=dict(headers),
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                body = response.read()
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            raise Error(
                f"{method} {urllib.parse.urlparse(url).path} failed with HTTP {exc.code}: {body}"
            ) from exc
        if not body:
            return None
        try:
            return cast(object, json.loads(body))
        except json.JSONDecodeError as exc:
            raise Error(f"{method} {url} returned invalid JSON") from exc


def response_items(response: object | None, description: str) -> object:
    if isinstance(response, dict) and "results" in response:
        return response["results"]
    if response is None:
        raise Error(f"{description} response was empty")
    return response


@dataclass
class PaperlessClient:
    settings: Settings
    transport: HttpTransport

    @property
    def headers(self) -> dict[str, str]:
        return {
            "Accept": "application/json",
            "Authorization": f"Token {self.settings.api_token.get_secret_value()}",
            "Content-Type": "application/json",
        }

    def api(self, method: str, path: str, payload: BaseModel | None = None) -> object | None:
        serialized = None if payload is None else payload.model_dump(mode="json", exclude_none=True)
        return self.transport.request(
            method,
            f"{self.settings.base_url}{path}",
            self.headers,
            serialized,
        )

    def wait_until_ready(self, waiter: Waiter) -> None:
        deadline = waiter.monotonic() + self.settings.wait_seconds
        last_error: Exception | None = None
        while waiter.monotonic() < deadline:
            try:
                self.api("GET", "/api/status/")
                return
            except (OSError, Error) as exc:
                last_error = exc
                waiter.sleep(self.settings.poll_seconds)
        raise Error(f"timed out waiting for Paperless API: {last_error}")

    def list_tags(self, **parameters: str) -> list[Tag]:
        query = urllib.parse.urlencode({"page_size": 100000, **parameters})
        response = self.api("GET", f"/api/tags/?{query}")
        try:
            return TAGS.validate_python(response_items(response, "tag list"))
        except ValidationError as exc:
            raise Error(f"invalid tag list response: {exc}") from exc

    def ensure_tag(self, name: str) -> Tag:
        for tag in self.list_tags(name__iexact=name):
            if tag.name.casefold() == name.casefold():
                return tag

        try:
            return Tag.model_validate(self.api("POST", "/api/tags/", TagPayload(name=name)))
        except ValidationError as exc:
            raise Error(f"invalid created tag response: {exc}") from exc

    def list_workflows(self) -> list[Workflow]:
        try:
            return WORKFLOWS.validate_python(
                response_items(self.api("GET", "/api/workflows/"), "workflow list")
            )
        except ValidationError as exc:
            raise Error(f"invalid workflow list response: {exc}") from exc

    def ensure_workflow(self, desired: DesiredWorkflow) -> None:
        workflow = next(
            (candidate for candidate in self.list_workflows() if candidate.name == desired.name),
            None,
        )
        payload = workflow_payload(desired, workflow)
        if workflow is None:
            self.api("POST", "/api/workflows/", payload)
        else:
            self.api("PATCH", f"/api/workflows/{workflow.id}/", payload)


def preserve_ids(
    desired: Sequence[WorkflowComponent], existing: Sequence[WorkflowComponent]
) -> list[WorkflowComponent]:
    return [
        component.model_copy(
            update={"id": existing[index].id}
            if index < len(existing) and existing[index].id is not None
            else {}
        )
        for index, component in enumerate(desired)
    ]


def workflow_payload(desired: DesiredWorkflow, existing: Workflow | None = None) -> WorkflowPayload:
    return WorkflowPayload(
        name=desired.name,
        triggers=preserve_ids(desired.triggers, () if existing is None else existing.triggers),
        actions=preserve_ids(desired.actions, () if existing is None else existing.actions),
    )


def desired_workflows(
    settings: Settings, tags: Mapping[str, Tag]
) -> tuple[DesiredWorkflow, DesiredWorkflow]:
    return (
        DesiredWorkflow(
            settings.auto_ocr_workflow_name,
            triggers=(WorkflowComponent(type=2),),
            actions=(WorkflowComponent(type=1, assign_tags=[tags[settings.auto_ocr_tag].id]),),
        ),
        DesiredWorkflow(
            settings.post_ocr_workflow_name,
            triggers=(
                WorkflowComponent(
                    type=3,
                    filter_has_tags=[tags[settings.ocr_complete_tag].id],
                    filter_has_not_tags=[tags[settings.auto_tag].id],
                ),
            ),
            actions=(
                WorkflowComponent(type=1, assign_tags=[tags[settings.auto_tag].id]),
                WorkflowComponent(type=2, remove_tags=[tags[settings.ocr_complete_tag].id]),
            ),
        ),
    )


def configure(settings: Settings, client: PaperlessClient, waiter: Waiter) -> None:
    client.wait_until_ready(waiter)
    tags = {
        name: client.ensure_tag(name)
        for name in (settings.auto_tag, settings.auto_ocr_tag, settings.ocr_complete_tag)
    }
    for desired in desired_workflows(settings, tags):
        client.ensure_workflow(desired)


def main() -> int:
    try:
        settings = Settings.from_environment()
        configure(
            settings,
            PaperlessClient(settings, UrllibTransport()),
            SystemWaiter(),
        )
    except Error as exc:
        print(f"paperless-gpt-configure: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
