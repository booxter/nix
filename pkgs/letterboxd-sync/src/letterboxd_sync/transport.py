from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal, Protocol, cast

from curl_cffi import CurlMime, requests

from .models import SyncError


@dataclass(frozen=True)
class Upload:
    name: str
    content: bytes


class Transport(Protocol):
    def request(
        self,
        method: Literal["GET", "POST"],
        path: str,
        *,
        data: Mapping[str, str] | bytes | None = None,
        upload: Upload | None = None,
    ) -> str: ...


class HttpTransport:
    def __init__(self, base_url: str, session: requests.Session) -> None:
        self.base_url = base_url.rstrip("/")
        self.session = session

    def request(
        self,
        method: Literal["GET", "POST"],
        path: str,
        *,
        data: Mapping[str, str] | bytes | None = None,
        upload: Upload | None = None,
    ) -> str:
        if not path.startswith("/") or path.startswith("//"):
            raise SyncError("Refusing a request outside the configured service")
        multipart = CurlMime() if upload else None
        try:
            if multipart is not None and upload is not None:
                multipart.addpart(
                    name="file", filename=upload.name, content_type="text/csv", data=upload.content
                )
            response = self.session.request(
                method,
                self.base_url + path,
                data=dict(data) if isinstance(data, Mapping) else data,
                multipart=multipart,
                headers={"Content-Type": "application/x-www-form-urlencoded"}
                if isinstance(data, bytes)
                else None,
                allow_redirects=False,
                timeout=60,
            )
            if response.status_code != 200:
                raise SyncError(f"Remote request failed (HTTP {response.status_code})")
            return cast(str, response.text)
        except requests.RequestsError:
            raise SyncError(
                "Remote request failed; check connectivity and session credentials"
            ) from None
        finally:
            if multipart is not None:
                multipart.close()
