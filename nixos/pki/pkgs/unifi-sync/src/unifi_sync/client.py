from __future__ import annotations

import base64
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.cookiejar import CookieJar
from typing import Any

from .errors import UnifiError


class UnifiLegacyClient:
    def __init__(
        self, base_url: str, api_key: str, site: str, verify_tls: bool, debug: bool
    ):
        if not base_url:
            raise UnifiError(
                "missing UniFi base URL; pass --base-url or set UNIFI_BASE_URL"
            )
        if not api_key:
            raise UnifiError(
                "missing UniFi API key; pass --api-key or set UNIFI_API_KEY"
            )

        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.site = site
        self.debug = debug
        self.cookie_jar: CookieJar = CookieJar()

        if verify_tls:
            context = ssl.create_default_context()
        else:
            context = ssl._create_unverified_context()

        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context),
            urllib.request.HTTPCookieProcessor(self.cookie_jar),
        )

    def _url(self, path: str) -> str:
        return f"{self.base_url}/proxy/network{path}"

    def _csrf_header(self) -> dict[str, str]:
        for cookie in self.cookie_jar:
            if cookie.name != "TOKEN":
                continue

            cookie_value = cookie.value
            if cookie_value is None:
                continue

            parts = cookie_value.split(".")
            if len(parts) < 2:
                continue

            payload = parts[1]
            payload += "=" * (-len(payload) % 4)
            try:
                decoded = base64.urlsafe_b64decode(payload.encode("ascii"))
                token = json.loads(decoded.decode("utf-8"))["csrfToken"]
            except (KeyError, ValueError, json.JSONDecodeError):
                continue
            return {"x-csrf-token": token}

        return {}

    def request_json(self, method: str, path: str, payload: Any | None = None) -> Any:
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-API-Key": self.api_key,
        }

        data = None
        if payload is not None:
            headers.update(self._csrf_header())
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")

        url = self._url(path)
        if self.debug:
            print(f"[debug] {method} {url}", file=sys.stderr)
            if payload is not None:
                formatted = json.dumps(payload, indent=2, sort_keys=True)
                print(f"[debug] payload={formatted}", file=sys.stderr)

        request = urllib.request.Request(url, method=method, headers=headers, data=data)
        try:
            with self.opener.open(request) as response:
                body = response.read().decode("utf-8")
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            raise UnifiError(
                f"{method} {url} failed with HTTP {error.code}\n{body}"
            ) from error
        except urllib.error.URLError as error:
            raise UnifiError(f"{method} {url} failed: {error.reason}") from error

        if self.debug and body:
            print(f"[debug] response={body}", file=sys.stderr)

        if not body:
            return None

        try:
            decoded = json.loads(body)
        except json.JSONDecodeError as error:
            raise UnifiError(
                f"{method} {url} returned invalid JSON:\n{body}"
            ) from error

        meta = decoded.get("meta")
        if isinstance(meta, dict) and meta.get("rc") not in (None, "ok"):
            raise UnifiError(f"{method} {url} returned rc={meta.get('rc')}:\n{body}")

        return decoded

    def request(self, method: str, path: str, payload: Any | None = None) -> Any:
        decoded = self.request_json(method, path, payload)
        return decoded.get("data", decoded)

    def list_known_clients(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/list/user")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for known clients")
        return data

    def list_usergroups(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/list/usergroup")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for user groups")
        return data

    def list_networks(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/rest/networkconf")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for networks")
        return data

    def list_dhcp_options(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/rest/dhcpoption")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for DHCP options")
        return data

    def create_dhcp_option(self, payload: dict[str, Any]) -> dict[str, Any]:
        data = self.request("POST", f"/api/s/{self.site}/rest/dhcpoption", payload)
        if (
            not isinstance(data, list)
            or len(data) != 1
            or not isinstance(data[0], dict)
        ):
            raise UnifiError("unexpected response shape when creating DHCP option")
        return data[0]

    def create_known_client(
        self,
        mac: str,
        usergroup_id: str,
        client_name: str | None,
    ) -> Any:
        client_data: dict[str, Any] = {
            "mac": mac,
            "usergroup_id": usergroup_id,
            "is_wired": True,
        }
        if client_name:
            client_data["name"] = client_name

        return self.request(
            "POST",
            f"/api/s/{self.site}/group/user",
            {"objects": [{"data": client_data}]},
        )

    def update_client(self, client_id: str, payload: dict[str, Any]) -> Any:
        return self.request(
            "PUT",
            f"/api/s/{self.site}/rest/user/{urllib.parse.quote(client_id, safe='')}",
            {"_id": client_id, **payload},
        )

    def update_network(self, network_id: str, payload: dict[str, Any]) -> Any:
        return self.request(
            "PUT",
            f"/api/s/{self.site}/rest/networkconf/{urllib.parse.quote(network_id, safe='')}",
            {"_id": network_id, **payload},
        )

    def list_static_routes(self) -> list[dict[str, Any]]:
        data = self.request("GET", f"/api/s/{self.site}/rest/routing")
        if not isinstance(data, list):
            raise UnifiError("unexpected response shape for static routes")
        return data

    def create_static_route(self, payload: dict[str, Any]) -> Any:
        return self.request("POST", f"/api/s/{self.site}/rest/routing", payload)

    def update_static_route(self, route_id: str, payload: dict[str, Any]) -> Any:
        return self.request(
            "PUT",
            f"/api/s/{self.site}/rest/routing/{urllib.parse.quote(route_id, safe='')}",
            {"_id": route_id, **payload},
        )

    def list_sites(self) -> list[dict[str, Any]]:
        return self._list_paginated("/integration/v1/sites")

    def list_dns_policies(self, site_id: str) -> list[dict[str, Any]]:
        return self._list_paginated(
            f"/integration/v1/sites/{urllib.parse.quote(site_id, safe='')}/dns/policies"
        )

    def create_dns_policy(self, site_id: str, payload: dict[str, Any]) -> Any:
        return self.request_json(
            "POST",
            f"/integration/v1/sites/{urllib.parse.quote(site_id, safe='')}/dns/policies",
            payload,
        )

    def update_dns_policy(
        self, site_id: str, policy_id: str, payload: dict[str, Any]
    ) -> Any:
        return self.request_json(
            "PUT",
            (
                f"/integration/v1/sites/{urllib.parse.quote(site_id, safe='')}/dns/policies/"
                f"{urllib.parse.quote(policy_id, safe='')}"
            ),
            payload,
        )

    def _list_paginated(self, path: str, limit: int = 200) -> list[dict[str, Any]]:
        offset = 0
        items: list[dict[str, Any]] = []

        while True:
            separator = "&" if "?" in path else "?"
            page = self.request_json(
                "GET",
                f"{path}{separator}offset={offset}&limit={limit}",
            )
            if not isinstance(page, dict):
                raise UnifiError(f"unexpected paginated response shape for {path}")

            data = page.get("data")
            if not isinstance(data, list):
                raise UnifiError(f"unexpected paginated data shape for {path}")

            items.extend(item for item in data if isinstance(item, dict))

            count = page.get("count")
            total_count = page.get("totalCount")
            if not isinstance(count, int) or count <= 0:
                break
            if isinstance(total_count, int) and offset + count >= total_count:
                break

            offset += count

        return items
