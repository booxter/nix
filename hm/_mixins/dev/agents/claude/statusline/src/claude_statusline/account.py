"""Reach Claude Code's credentials and Claude's usage API."""

import subprocess
import urllib.error
import urllib.request

CREDENTIALS_SERVICE = "Claude Code-credentials"
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TIMEOUT_SECONDS = 10


class SecurityKeychain:
    """Read Claude Code's credentials with the macOS security tool.

    Claude Code saves this Keychain item with /usr/bin/security, so that tool
    may read it without a prompt. Other readers, such as Python's Keychain
    bindings from a Nix store path that changes on every rebuild, would ask
    again and again.
    """

    def __init__(self, executable: str = "/usr/bin/security") -> None:
        self.executable = executable

    def read_credentials(self) -> str | None:
        try:
            result = subprocess.run(
                [self.executable, "find-generic-password", "-s", CREDENTIALS_SERVICE, "-w"],
                capture_output=True,
                text=True,
                timeout=TIMEOUT_SECONDS,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None

        if result.returncode != 0:
            return None
        return result.stdout


class UrllibUsageApi:
    def __init__(self, url: str = USAGE_URL) -> None:
        self.url = url

    def get_usage(self, access_token: str) -> str | None:
        request = urllib.request.Request(
            self.url,
            headers={
                "Accept": "application/json",
                "Authorization": f"Bearer {access_token}",
                "anthropic-beta": "oauth-2025-04-20",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
                body: bytes = response.read()
        except (urllib.error.URLError, TimeoutError):
            return None

        return body.decode("utf-8", errors="replace")
