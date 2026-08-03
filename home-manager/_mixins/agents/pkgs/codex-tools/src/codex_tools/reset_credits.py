from dataclasses import dataclass

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import JsonHttpClient
from codex_tools.json import JsonObject
from codex_tools.payloads import ResetCreditsPayload, validate_payload
from codex_tools.usage import RESET_CREDITS_ENDPOINT


@dataclass(frozen=True)
class ResetCreditsReport:
    available_count: int
    expirations: tuple[str | None, ...]

    @classmethod
    def from_json(cls, response: JsonObject) -> "ResetCreditsReport":
        payload = validate_payload(
            ResetCreditsPayload,
            response,
            source="reset credits response",
        )
        available_count = payload.available_count
        if available_count is None:
            raise CodexToolsError("Unexpected response: missing available_count")
        return cls(
            available_count=available_count,
            expirations=tuple(credit.expires_at for credit in payload.credits),
        )


@dataclass(frozen=True)
class ResetCreditsService:
    client: JsonHttpClient
    endpoint: str = RESET_CREDITS_ENDPOINT

    def fetch(self, auth: CodexAuth) -> ResetCreditsReport:
        response = self.client.get_json(
            self.endpoint,
            headers={"Authorization": f"Bearer {auth.access_token}"},
        )
        return ResetCreditsReport.from_json(response)


def format_reset_credits(report: ResetCreditsReport) -> str:
    lines = [f"available_count: {report.available_count}", "credits:"]
    lines.extend(
        f"  - expires_at: {expiration or '<missing>'}" for expiration in report.expirations
    )
    return "\n".join(lines)
