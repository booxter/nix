from __future__ import annotations

import ipaddress
import json
from dataclasses import dataclass
from typing import Any, Protocol

from .errors import UnifiError


SUPPORTED_RECORD_TYPES = {"A_RECORD", "CNAME_RECORD"}


@dataclass(frozen=True)
class DnsRecordSpec:
    record_type: str
    domain: str
    ttl_seconds: int
    enabled: bool = True
    ipv4_address: ipaddress.IPv4Address | None = None
    target_domain: str | None = None


class Client(Protocol):
    def list_sites(self) -> list[dict[str, Any]]: ...

    def list_dns_policies(self, site_id: str) -> list[dict[str, Any]]: ...

    def create_dns_policy(self, site_id: str, payload: dict[str, Any]) -> Any: ...

    def update_dns_policy(
        self, site_id: str, policy_id: str, payload: dict[str, Any]
    ) -> Any: ...


def normalize_dns_name(value: str) -> str:
    normalized = value.strip().rstrip(".").lower()
    if not normalized:
        raise UnifiError("DNS name must not be empty")
    labels = normalized.split(".")
    for label in labels:
        if not label:
            raise UnifiError(f"DNS name has an empty label: {value}")
        if len(label.encode("idna")) > 63:
            raise UnifiError(f"DNS label is too long in {value}")
    encoded_length = sum(len(label.encode("idna")) + 1 for label in labels) + 1
    if encoded_length > 255:
        raise UnifiError(f"DNS name is too long: {value}")
    return normalized


def parse_records(raw_json: str) -> list[DnsRecordSpec] | None:
    if not raw_json:
        return None
    try:
        decoded = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise UnifiError(f"invalid DNS records JSON: {error}") from error
    if not isinstance(decoded, list):
        raise UnifiError("DNS records JSON must be a list")

    records: list[DnsRecordSpec] = []
    for index, item in enumerate(decoded):
        if not isinstance(item, dict):
            raise UnifiError(f"DNS record item {index} is not an object")
        record_type = item.get("type")
        domain = item.get("domain")
        ttl_seconds = item.get("ttlSeconds")
        enabled = item.get("enabled", True)
        if not isinstance(record_type, str):
            raise UnifiError(f"DNS record item {index} is missing type")
        if not isinstance(domain, str):
            raise UnifiError(f"DNS record item {index} is missing domain")
        if not isinstance(ttl_seconds, int) or ttl_seconds < 0:
            raise UnifiError(
                f"DNS record item {index} is missing non-negative integer ttlSeconds"
            )
        if not isinstance(enabled, bool):
            raise UnifiError(f"DNS record item {index} enabled must be boolean")

        normalized_type = record_type.strip().upper()
        if normalized_type not in SUPPORTED_RECORD_TYPES:
            supported = ", ".join(sorted(SUPPORTED_RECORD_TYPES))
            raise UnifiError(
                f"DNS record item {index} uses unsupported type {record_type!r}; "
                f"supported: {supported}"
            )
        normalized_domain = normalize_dns_name(domain)
        if normalized_type == "A_RECORD":
            ipv4_address = item.get("ipv4Address")
            if not isinstance(ipv4_address, str):
                raise UnifiError(f"DNS A record item {index} is missing ipv4Address")
            parsed_ip = ipaddress.ip_address(ipv4_address)
            if not isinstance(parsed_ip, ipaddress.IPv4Address):
                raise UnifiError(
                    f"DNS A record item {index} is not IPv4: {ipv4_address}"
                )
            records.append(
                DnsRecordSpec(
                    record_type=normalized_type,
                    domain=normalized_domain,
                    ttl_seconds=ttl_seconds,
                    enabled=enabled,
                    ipv4_address=parsed_ip,
                )
            )
            continue

        target_domain = item.get("targetDomain")
        if not isinstance(target_domain, str):
            raise UnifiError(f"DNS CNAME record item {index} is missing targetDomain")
        records.append(
            DnsRecordSpec(
                record_type=normalized_type,
                domain=normalized_domain,
                ttl_seconds=ttl_seconds,
                enabled=enabled,
                target_domain=normalize_dns_name(target_domain),
            )
        )
    return records


def _stringify(value: object) -> str | None:
    return None if value is None else str(value)


def _change(current: object, desired: object) -> dict[str, object]:
    return {"current": current, "desired": desired}


def choose_site(sites: list[dict[str, Any]], requested_site: str) -> dict[str, Any]:
    matches = [
        site
        for site in sites
        if requested_site
        in {
            _stringify(site.get("id")),
            _stringify(site.get("internalReference")),
            _stringify(site.get("name")),
        }
    ]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        choices = ", ".join(
            f"{site.get('name', '<unnamed>')}"
            f"[{site.get('internalReference', '?')}:{site.get('id', '?')}]"
            for site in matches
        )
        raise UnifiError(f"multiple UniFi sites match {requested_site!r}: {choices}")
    if len(sites) == 1:
        return sites[0]
    choices = ", ".join(
        f"{site.get('name', '<unnamed>')}"
        f"[{site.get('internalReference', '?')}:{site.get('id', '?')}]"
        for site in sites
    )
    raise UnifiError(
        f"could not match UniFi site {requested_site!r} in official API site list. "
        f"Available: {choices}"
    )


def policy_key(record_type: str, domain: str) -> tuple[str, str]:
    return record_type.upper(), normalize_dns_name(domain)


def policies_by_key(
    policies: list[dict[str, Any]],
) -> dict[tuple[str, str], dict[str, Any]]:
    by_key: dict[tuple[str, str], dict[str, Any]] = {}
    for policy in policies:
        record_type = policy.get("type")
        domain = policy.get("domain")
        if not isinstance(record_type, str) or not isinstance(domain, str):
            continue
        key = policy_key(record_type, domain)
        if key in by_key:
            raise UnifiError(
                f"multiple UniFi DNS policies share the same key {record_type}:{domain}"
            )
        by_key[key] = policy
    return by_key


def policy_payload(record: DnsRecordSpec) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "enabled": record.enabled,
        "type": record.record_type,
        "domain": record.domain,
        "ttlSeconds": record.ttl_seconds,
    }
    if record.record_type == "A_RECORD":
        payload["ipv4Address"] = str(record.ipv4_address)
    elif record.record_type == "CNAME_RECORD":
        payload["targetDomain"] = record.target_domain
    else:
        raise UnifiError(f"unsupported DNS record type: {record.record_type}")
    return payload


def update_plan(
    existing_policy: dict[str, Any] | None,
    record: DnsRecordSpec,
) -> tuple[str, dict[str, Any], dict[str, Any]]:
    desired_payload = policy_payload(record)
    changes: dict[str, Any] = {}
    if existing_policy is None:
        for key, value in desired_payload.items():
            changes[key] = _change(None, value)
        return "create", desired_payload, changes

    current_enabled = bool(existing_policy.get("enabled"))
    if current_enabled != record.enabled:
        changes["enabled"] = _change(current_enabled, record.enabled)
    current_domain = _stringify(existing_policy.get("domain"))
    if current_domain != record.domain:
        changes["domain"] = _change(current_domain, record.domain)
    current_ttl = existing_policy.get("ttlSeconds")
    if current_ttl != record.ttl_seconds:
        changes["ttlSeconds"] = _change(current_ttl, record.ttl_seconds)
    if record.record_type == "A_RECORD":
        current_address = _stringify(existing_policy.get("ipv4Address"))
        desired_address = str(record.ipv4_address)
        if current_address != desired_address:
            changes["ipv4Address"] = _change(current_address, desired_address)
    elif record.record_type == "CNAME_RECORD":
        current_target = _stringify(existing_policy.get("targetDomain"))
        if current_target != record.target_domain:
            changes["targetDomain"] = _change(current_target, record.target_domain)
    else:
        raise UnifiError(f"unsupported DNS record type: {record.record_type}")
    if changes:
        return "update", desired_payload, changes
    return "noop", {}, {}


def sync_records(
    client: Client,
    requested_site: str,
    records: list[DnsRecordSpec],
    dry_run: bool,
) -> dict[str, Any]:
    if not records:
        return {
            "site_id": None,
            "site_name": None,
            "site_internal_reference": None,
            "dry_run": dry_run,
            "count": 0,
            "changed_count": 0,
            "results": [],
        }

    selected_site = choose_site(client.list_sites(), requested_site)
    site_id = _stringify(selected_site.get("id"))
    if not site_id:
        raise UnifiError("selected official UniFi site has no id")
    existing_by_key = policies_by_key(client.list_dns_policies(site_id))
    results: list[dict[str, Any]] = []
    for record in records:
        existing = existing_by_key.get(policy_key(record.record_type, record.domain))
        action, payload, changes = update_plan(existing, record)
        changed = bool(payload)
        result = None
        if changed and not dry_run:
            if existing is None:
                result = client.create_dns_policy(site_id, payload)
            else:
                policy_id = _stringify(existing.get("id"))
                if not policy_id:
                    raise UnifiError(
                        f"existing UniFi DNS policy for {record.domain} has no id"
                    )
                result = client.update_dns_policy(site_id, policy_id, payload)
        results.append(
            {
                "type": record.record_type,
                "domain": record.domain,
                "enabled": record.enabled,
                "policy_id": _stringify(existing.get("id")) if existing else None,
                "action": action,
                "changed": changed,
                "dry_run": dry_run,
                "changes": changes,
                "result": result,
            }
        )
    return {
        "site_id": site_id,
        "site_name": selected_site.get("name"),
        "site_internal_reference": selected_site.get("internalReference"),
        "dry_run": dry_run,
        "count": len(results),
        "changed_count": sum(1 for result in results if result["changed"]),
        "results": results,
    }
