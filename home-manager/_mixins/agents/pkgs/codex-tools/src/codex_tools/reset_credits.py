from dataclasses import dataclass

from codex_tools.auth import CodexAuth
from codex_tools.errors import CodexToolsError
from codex_tools.http import JsonHttpClient
from codex_tools.json import JsonObject, integer_value, object_list, string_value
from codex_tools.usage import RESET_CREDITS_ENDPOINT


@dataclass(frozen=True)
class ResetCreditsReport:
    available_count: int
    expirations: tuple[str | None, ...]

    @classmethod
    def from_json(cls, response: JsonObject) -> "ResetCreditsReport":
        available_count = integer_value(response.get("available_count"))
        if available_count is None:
            raise CodexToolsError("Unexpected response: missing available_count")
        return cls(
            available_count=available_count,
            expirations=tuple(
                string_value(credit.get("expires_at"))
                for credit in object_list(response, "credits")
            ),
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
