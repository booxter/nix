#!/usr/bin/env python3
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path


DEFAULT_SEERR_URL = "http://127.0.0.1:5055"
DEFAULT_SETTINGS_FILE = "/data/.state/nixarr/seerr/settings.json"
DEFAULT_BATCH_SIZE = 500
ELIGIBLE_REQUEST_STATUSES = {2, 5}  # approved, completed


class UpdateError(RuntimeError):
    pass


class JsonClient:
    def __init__(self, *, timeout):
        self.timeout = timeout

    def request(self, base_url, path, api_key, *, method="GET", body=None, query=None):
        url = base_url.rstrip("/") + "/" + path.lstrip("/")
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "X-Api-Key": api_key,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace").strip()
            raise UpdateError(
                f"{method} {url} failed with HTTP {error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise UpdateError(f"{method} {url} failed: {error.reason}") from error

        if not payload:
            return None
        try:
            return json.loads(payload)
        except json.JSONDecodeError as error:
            raise UpdateError(f"{method} {url} returned invalid JSON") from error


def sanitize_display_name(display_name):
    normalized = unicodedata.normalize("NFD", display_name)
    normalized = "".join(
        character for character in normalized if not 0x0300 <= ord(character) <= 0x036F
    )
    normalized = re.sub(r"\s+", "-", normalized)
    normalized = re.sub(r"[^A-Za-z0-9-]", "", normalized)
    normalized = re.sub(r"-+", "-", normalized)
    return normalized.strip("-")


def expected_tag(user):
    return f"{user['id']}-{sanitize_display_name(user['displayName'])}"


def find_user_tag(tags, user_id):
    old_prefix = f"{user_id} - "
    new_prefix = f"{user_id}-"
    return next(
        (
            tag
            for tag in tags
            if tag.get("label", "").startswith(old_prefix)
            or tag.get("label", "").startswith(new_prefix)
        ),
        None,
    )


def service_base_url(service):
    scheme = "https" if service.get("useSsl") else "http"
    hostname = service["hostname"]
    if ":" in hostname and not hostname.startswith("["):
        hostname = f"[{hostname}]"
    base_path = "/" + service.get("baseUrl", "").strip("/")
    if base_path == "/":
        base_path = ""
    return f"{scheme}://{hostname}:{service['port']}{base_path}/api/v3"


def read_api_key(path):
    env_key = os.environ.get("SEERR_API_KEY", "").strip()
    if env_key:
        return env_key

    try:
        text = Path(path).read_text(encoding="utf-8").strip()
    except OSError as error:
        raise UpdateError(
            f"could not read Seerr API key from {path}: {error}; "
            "set SEERR_API_KEY or use --api-key-file"
        ) from error
    if not text:
        raise UpdateError(f"Seerr API key file is empty: {path}")

    try:
        settings = json.loads(text)
    except json.JSONDecodeError:
        return text
    try:
        key = settings["main"]["apiKey"].strip()
    except (KeyError, TypeError, AttributeError) as error:
        raise UpdateError(f"no main.apiKey found in {path}") from error
    if not key:
        raise UpdateError(f"main.apiKey is empty in {path}")
    return key


def paginated_requests(client, seerr_url, api_key, page_size):
    skip = 0
    seen_ids = set()
    while True:
        response = client.request(
            seerr_url,
            "/api/v1/request",
            api_key,
            query={"take": page_size, "skip": skip},
        )
        results = response.get("results", [])
        if not results:
            return
        new_results = [
            request for request in results if request.get("id") not in seen_ids
        ]
        if not new_results:
            raise UpdateError("Seerr request pagination repeated a page")
        for request in new_results:
            seen_ids.add(request.get("id"))
            yield request
        skip += len(results)
        total = response.get("pageInfo", {}).get("results")
        if len(results) < page_size or (isinstance(total, int) and skip >= total):
            return


def service_for_request(request, services):
    service_id = request.get("serverId")
    media = request.get("media") or {}
    if service_id is None:
        service_id = media.get("serviceId4k" if request.get("is4k") else "serviceId")
    return services.get(service_id)


def item_external_id(request):
    media = request.get("media") or {}
    if request.get("type") == "movie":
        return media.get("tmdbId")
    if request.get("type") == "tv":
        return media.get("tvdbId")
    return None


def inventory_for_service(client, kind, service):
    endpoint = "/movie" if kind == "radarr" else "/series"
    external_id_key = "tmdbId" if kind == "radarr" else "tvdbId"
    base_url = service_base_url(service)
    items = client.request(base_url, endpoint, service["apiKey"])
    inventory = {
        item[external_id_key]: item
        for item in items
        if item.get(external_id_key) is not None
    }
    tags = client.request(base_url, "/tag", service["apiKey"])
    return base_url, inventory, tags


def batches(values, size):
    for offset in range(0, len(values), size):
        yield values[offset : offset + size]


def update_user_tags(args, *, client=None, output=print):
    client = client or JsonClient(timeout=args.timeout)
    seerr_api_key = read_api_key(args.api_key_file)
    radarr_settings = client.request(
        args.seerr_url, "/api/v1/settings/radarr", seerr_api_key
    )
    sonarr_settings = client.request(
        args.seerr_url, "/api/v1/settings/sonarr", seerr_api_key
    )
    services_by_kind = {
        "radarr": {service["id"]: service for service in radarr_settings},
        "sonarr": {service["id"]: service for service in sonarr_settings},
    }
    enabled_services = {
        (kind, service_id): service
        for kind, services in services_by_kind.items()
        for service_id, service in services.items()
        if service.get("tagRequests")
    }
    if not enabled_services:
        raise UpdateError(
            "no Radarr or Sonarr instances have requester tagging enabled"
        )

    selected_users = set(args.user)
    requests = list(
        paginated_requests(client, args.seerr_url, seerr_api_key, args.page_size)
    )
    desired_external_ids = defaultdict(lambda: defaultdict(set))
    users = {}
    stats = defaultdict(int)
    stats["requests"] = len(requests)

    for request in requests:
        if request.get("status") not in ELIGIBLE_REQUEST_STATUSES:
            stats["ineligible_status"] += 1
            continue
        user = request.get("requestedBy") or {}
        user_id = user.get("id")
        if user_id is None or "displayName" not in user:
            stats["missing_user"] += 1
            continue
        if selected_users and user_id not in selected_users:
            continue
        kind = "radarr" if request.get("type") == "movie" else "sonarr"
        service = service_for_request(request, services_by_kind[kind])
        if service is None:
            stats["missing_service"] += 1
            continue
        service_key = (kind, service["id"])
        if service_key not in enabled_services:
            stats["tagging_disabled"] += 1
            continue
        external_id = item_external_id(request)
        if external_id is None:
            stats["missing_external_id"] += 1
            continue
        users[user_id] = user
        desired_external_ids[service_key][user_id].add(external_id)
        stats["eligible_requests"] += 1

    stats["unique_attributions"] = sum(
        len(external_ids)
        for service_users in desired_external_ids.values()
        for external_ids in service_users.values()
    )

    mode = "APPLY" if args.apply else "DRY RUN"
    output(
        f"{mode}: {'changes will be written' if args.apply else 'no changes will be made'}"
    )

    for service_key in sorted(desired_external_ids):
        kind, _service_id = service_key
        service = enabled_services[service_key]
        label = f"{kind.capitalize()} {service.get('name', service['id'])}"
        base_url, inventory, tags = inventory_for_service(client, kind, service)
        output(f"\n{label}: {len(inventory)} items, {len(tags)} tags")

        for user_id in sorted(desired_external_ids[service_key]):
            user = users[user_id]
            tag = find_user_tag(tags, user_id)
            tag_label = tag["label"] if tag else expected_tag(user)
            target_items = []
            for external_id in sorted(desired_external_ids[service_key][user_id]):
                item = inventory.get(external_id)
                if item is None:
                    stats["missing_items"] += 1
                    if args.verbose:
                        output(f"  MISSING {tag_label}: external ID {external_id}")
                    continue
                if tag and tag["id"] in item.get("tags", []):
                    stats["already_tagged"] += 1
                    continue
                target_items.append(item)

            if not target_items:
                continue
            if tag is None:
                stats["tags_to_create"] += 1
                output(
                    f"  {'CREATE' if args.apply else 'WOULD CREATE'} tag {tag_label}"
                )
                if args.apply:
                    tag = client.request(
                        base_url,
                        "/tag",
                        service["apiKey"],
                        method="POST",
                        body={"label": tag_label},
                    )
                    tags.append(tag)

            item_ids = sorted(item["id"] for item in target_items)
            stats["items_to_update"] += len(item_ids)
            noun = "movies" if kind == "radarr" else "series"
            action = "ADD" if args.apply else "WOULD ADD"
            output(f"  {action} {tag_label} to {len(item_ids)} {noun}")
            if args.verbose:
                for item in sorted(
                    target_items, key=lambda value: value.get("title", "")
                ):
                    output(f"    - {item.get('title', item['id'])}")
            if args.apply:
                editor = "/movie/editor" if kind == "radarr" else "/series/editor"
                ids_key = "movieIds" if kind == "radarr" else "seriesIds"
                for item_id_batch in batches(item_ids, args.batch_size):
                    client.request(
                        base_url,
                        editor,
                        service["apiKey"],
                        method="PUT",
                        body={
                            ids_key: item_id_batch,
                            "tags": [tag["id"]],
                            "applyTags": "add",
                        },
                    )

    output("\nSummary:")
    output(f"  requests scanned: {stats['requests']}")
    output(f"  eligible requests: {stats['eligible_requests']}")
    output(f"  unique user/item attributions: {stats['unique_attributions']}")
    output(
        f"  tags {'created' if args.apply else 'to create'}: {stats['tags_to_create']}"
    )
    output(
        f"  items {'updated' if args.apply else 'to update'}: {stats['items_to_update']}"
    )
    output(f"  items already tagged: {stats['already_tagged']}")
    output(f"  requested items absent from Radarr/Sonarr: {stats['missing_items']}")
    skipped = sum(
        stats[key]
        for key in (
            "ineligible_status",
            "missing_user",
            "missing_service",
            "tagging_disabled",
            "missing_external_id",
        )
    )
    output(f"  requests skipped: {skipped}")
    return dict(stats)


def build_parser():
    parser = argparse.ArgumentParser(
        description=(
            "Backfill Seerr requester tags on existing Radarr and Sonarr items. "
            "Runs read-only unless --apply is supplied."
        )
    )
    parser.add_argument(
        "--apply", action="store_true", help="Create missing tags and update items"
    )
    parser.add_argument(
        "--ssh-host",
        default="srvarr",
        help="Host on which to run the updater (default: srvarr)",
    )
    parser.add_argument(
        "--local",
        action="store_true",
        help="Run locally instead of streaming the updater to --ssh-host",
    )
    parser.add_argument("--seerr-url", default=DEFAULT_SEERR_URL)
    parser.add_argument(
        "--api-key-file",
        default=DEFAULT_SETTINGS_FILE,
        help=(
            "File containing the Seerr API key or settings.json "
            f"(default: {DEFAULT_SETTINGS_FILE})"
        ),
    )
    parser.add_argument("--page-size", type=int, default=100)
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Maximum items per Radarr/Sonarr update (default: {DEFAULT_BATCH_SIZE})",
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--user",
        action="append",
        type=int,
        default=[],
        help="Only backfill this Seerr user ID; may be repeated",
    )
    parser.add_argument("--verbose", action="store_true", help="List individual titles")
    return parser


def dispatch_remote(args):
    source = Path(__file__).read_text(encoding="utf-8")
    remote_args = [
        "sudo",
        "-n",
        "--user=seerr",
        "--",
        "/run/current-system/sw/bin/python3",
        "-",
        "--local",
        "--seerr-url",
        args.seerr_url,
        "--api-key-file",
        args.api_key_file,
        "--page-size",
        str(args.page_size),
        "--batch-size",
        str(args.batch_size),
        "--timeout",
        str(args.timeout),
    ]
    if args.apply:
        remote_args.append("--apply")
    if args.verbose:
        remote_args.append("--verbose")
    for user_id in args.user:
        remote_args.extend(["--user", str(user_id)])
    result = subprocess.run(
        ["ssh", "-T", args.ssh_host, shlex.join(remote_args)],
        input=source,
        text=True,
        check=False,
    )
    return result.returncode


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.page_size < 1:
        raise UpdateError("--page-size must be positive")
    if args.batch_size < 1:
        raise UpdateError("--batch-size must be positive")
    if args.timeout <= 0:
        raise UpdateError("--timeout must be positive")
    if not args.local:
        return dispatch_remote(args)
    update_user_tags(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (UpdateError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
