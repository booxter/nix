#!/usr/bin/env python3
import argparse
import json
import os
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from fractions import Fraction
from pathlib import Path


DEFAULT_SEERR_URL = "http://127.0.0.1:5055"
DEFAULT_SETTINGS_FILE = "/data/.state/nixarr/seerr/settings.json"
ELIGIBLE_REQUEST_STATUSES = {2, 5}  # approved, completed


class ReportError(RuntimeError):
    pass


class JsonClient:
    def __init__(self, *, timeout):
        self.timeout = timeout

    def get(self, base_url, path, api_key, *, query=None):
        url = base_url.rstrip("/") + "/" + path.lstrip("/")
        if query:
            url += "?" + urllib.parse.urlencode(query, doseq=True)
        request = urllib.request.Request(
            url,
            headers={"Accept": "application/json", "X-Api-Key": api_key},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace").strip()
            raise ReportError(
                f"GET {url} failed with HTTP {error.code}: {detail}"
            ) from error
        except urllib.error.URLError as error:
            raise ReportError(f"GET {url} failed: {error.reason}") from error
        try:
            return json.loads(payload)
        except json.JSONDecodeError as error:
            raise ReportError(f"GET {url} returned invalid JSON") from error


def read_api_key(path):
    env_key = os.environ.get("SEERR_API_KEY", "").strip()
    if env_key:
        return env_key
    try:
        text = Path(path).read_text(encoding="utf-8").strip()
    except OSError as error:
        raise ReportError(
            f"could not read Seerr API key from {path}: {error}; "
            "set SEERR_API_KEY or use --api-key-file"
        ) from error
    if not text:
        raise ReportError(f"Seerr API key file is empty: {path}")
    try:
        settings = json.loads(text)
    except json.JSONDecodeError:
        return text
    try:
        key = settings["main"]["apiKey"].strip()
    except (KeyError, TypeError, AttributeError) as error:
        raise ReportError(f"no main.apiKey found in {path}") from error
    if not key:
        raise ReportError(f"main.apiKey is empty in {path}")
    return key


def service_base_url(service):
    scheme = "https" if service.get("useSsl") else "http"
    hostname = service["hostname"]
    if ":" in hostname and not hostname.startswith("["):
        hostname = f"[{hostname}]"
    base_path = "/" + service.get("baseUrl", "").strip("/")
    if base_path == "/":
        base_path = ""
    return f"{scheme}://{hostname}:{service['port']}{base_path}/api/v3"


def paginated_requests(client, seerr_url, api_key, page_size):
    skip = 0
    seen_ids = set()
    while True:
        response = client.get(
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
            raise ReportError("Seerr request pagination repeated a page")
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


def movie_size(movie):
    size = movie.get("sizeOnDisk")
    if not isinstance(size, int):
        size = (movie.get("movieFile") or {}).get("size", 0)
    return max(size, 0) if isinstance(size, int) else 0


def request_seasons(request):
    return {
        season["seasonNumber"]
        for season in request.get("seasons", [])
        if isinstance(season.get("seasonNumber"), int)
    }


def collect_desired_requests(requests, services_by_kind):
    movies = defaultdict(lambda: defaultdict(set))
    series = defaultdict(lambda: defaultdict(lambda: defaultdict(set)))
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
        media = request.get("media") or {}
        request_type = request.get("type")
        if request_type not in {"movie", "tv"}:
            stats["unknown_type"] += 1
            continue
        kind = "radarr" if request_type == "movie" else "sonarr"
        service = service_for_request(request, services_by_kind[kind])
        if service is None:
            stats["missing_service"] += 1
            continue
        users[user_id] = user
        if request_type == "movie":
            tmdb_id = media.get("tmdbId")
            if tmdb_id is None:
                stats["missing_external_id"] += 1
                continue
            movies[service["id"]][tmdb_id].add(user_id)
        else:
            tvdb_id = media.get("tvdbId")
            seasons = request_seasons(request)
            if tvdb_id is None:
                stats["missing_external_id"] += 1
                continue
            if not seasons:
                stats["missing_seasons"] += 1
                continue
            for season_number in seasons:
                series[service["id"]][tvdb_id][season_number].add(user_id)
        stats["eligible_requests"] += 1
    return movies, series, users, stats


def add_file(file_users, file_sizes, file_key, size, user_ids):
    if size <= 0:
        return False
    file_sizes[file_key] = size
    file_users[file_key].update(user_ids)
    return True


def build_report(args, *, client=None):
    client = client or JsonClient(timeout=args.timeout)
    seerr_api_key = read_api_key(args.api_key_file)
    radarr_settings = client.get(
        args.seerr_url, "/api/v1/settings/radarr", seerr_api_key
    )
    sonarr_settings = client.get(
        args.seerr_url, "/api/v1/settings/sonarr", seerr_api_key
    )
    services_by_kind = {
        "radarr": {service["id"]: service for service in radarr_settings},
        "sonarr": {service["id"]: service for service in sonarr_settings},
    }
    requests = list(
        paginated_requests(client, args.seerr_url, seerr_api_key, args.page_size)
    )
    desired_movies, desired_series, users, stats = collect_desired_requests(
        requests, services_by_kind
    )

    file_users = defaultdict(set)
    file_sizes = {}
    user_movies = defaultdict(set)
    user_series = defaultdict(set)
    user_seasons = defaultdict(set)

    for service_id, movies_by_tmdb in desired_movies.items():
        service = services_by_kind["radarr"][service_id]
        base_url = service_base_url(service)
        inventory = {
            movie["tmdbId"]: movie
            for movie in client.get(base_url, "/movie", service["apiKey"])
            if movie.get("tmdbId") is not None
        }
        for tmdb_id, user_ids in movies_by_tmdb.items():
            movie = inventory.get(tmdb_id)
            if movie is None:
                stats["missing_movies"] += 1
                continue
            movie_key = (service_id, movie["id"])
            for user_id in user_ids:
                user_movies[user_id].add(movie_key)
            file_id = (movie.get("movieFile") or {}).get("id", movie["id"])
            file_key = ("movie", service_id, file_id)
            if not add_file(
                file_users, file_sizes, file_key, movie_size(movie), user_ids
            ):
                stats["movies_without_files"] += 1

    for service_id, series_by_tvdb in desired_series.items():
        service = services_by_kind["sonarr"][service_id]
        base_url = service_base_url(service)
        inventory = {
            series["tvdbId"]: series
            for series in client.get(base_url, "/series", service["apiKey"])
            if series.get("tvdbId") is not None
        }
        for tvdb_id, seasons in series_by_tvdb.items():
            series = inventory.get(tvdb_id)
            if series is None:
                stats["missing_series"] += 1
                continue
            episode_files = client.get(
                base_url,
                "/episodefile",
                service["apiKey"],
                query={"seriesId": series["id"]},
            )
            files_by_season = defaultdict(list)
            for episode_file in episode_files:
                files_by_season[episode_file.get("seasonNumber")].append(episode_file)
            for season_number, user_ids in seasons.items():
                series_key = (service_id, series["id"])
                season_key = (service_id, series["id"], season_number)
                for user_id in user_ids:
                    user_series[user_id].add(series_key)
                    user_seasons[user_id].add(season_key)
                episode_files_for_season = files_by_season.get(season_number, [])
                if not episode_files_for_season:
                    stats["seasons_without_files"] += 1
                    continue
                for episode_file in episode_files_for_season:
                    size = episode_file.get("size", 0)
                    file_key = ("episode", service_id, episode_file["id"])
                    if not add_file(file_users, file_sizes, file_key, size, user_ids):
                        stats["episode_files_without_size"] += 1

    per_user_files = defaultdict(set)
    for file_key, user_ids in file_users.items():
        for user_id in user_ids:
            per_user_files[user_id].add(file_key)

    rows = []
    distinct_bytes = sum(file_sizes.values())
    for user_id, user in users.items():
        logical = sum(file_sizes[file_key] for file_key in per_user_files[user_id])
        movie_bytes = sum(
            file_sizes[file_key]
            for file_key in per_user_files[user_id]
            if file_key[0] == "movie"
        )
        tv_bytes = logical - movie_bytes
        allocated = sum(
            Fraction(file_sizes[file_key], len(file_users[file_key]))
            for file_key in per_user_files[user_id]
        )
        exclusive = sum(
            file_sizes[file_key]
            for file_key in per_user_files[user_id]
            if len(file_users[file_key]) == 1
        )
        rows.append(
            {
                "userId": user_id,
                "displayName": user["displayName"],
                "movies": len(user_movies[user_id]),
                "series": len(user_series[user_id]),
                "seasons": len(user_seasons[user_id]),
                "files": len(per_user_files[user_id]),
                "movieBytes": movie_bytes,
                "tvBytes": tv_bytes,
                "logicalBytes": logical,
                "allocatedBytes": round(allocated),
                "allocatedPercent": (
                    round(float(allocated) / distinct_bytes * 100, 4)
                    if distinct_bytes
                    else 0.0
                ),
                "exclusiveBytes": exclusive,
            }
        )
    rows.sort(key=lambda row: (-row["logicalBytes"], row["userId"]))

    logical_bytes = sum(row["logicalBytes"] for row in rows)
    attributed_files = len(file_sizes)
    return {
        "users": rows,
        "totals": {
            "distinctBytes": distinct_bytes,
            "movieBytes": sum(
                size for file_key, size in file_sizes.items() if file_key[0] == "movie"
            ),
            "tvBytes": sum(
                size
                for file_key, size in file_sizes.items()
                if file_key[0] == "episode"
            ),
            "logicalBytes": logical_bytes,
            "files": attributed_files,
            "sharedFiles": sum(1 for owners in file_users.values() if len(owners) > 1),
        },
        "unresolved": {
            "moviesNotInRadarr": stats["missing_movies"],
            "moviesWithoutFiles": stats["movies_without_files"],
            "seriesNotInSonarr": stats["missing_series"],
            "seasonsWithoutFiles": stats["seasons_without_files"],
        },
        "requests": {
            "scanned": stats["requests"],
            "eligible": stats["eligible_requests"],
            "skipped": stats["requests"] - stats["eligible_requests"],
        },
    }


def format_bytes(value):
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    amount = float(value)
    for unit in units:
        if abs(amount) < 1024 or unit == units[-1]:
            return f"{amount:.1f} {unit}" if unit != "B" else f"{amount:.0f} B"
        amount /= 1024
    raise AssertionError("unreachable")


def render_table(report):
    headers = [
        "ID",
        "User",
        "Movies",
        "Movie data",
        "Series",
        "Seasons",
        "TV data",
        "Files",
        "Logical",
        "Allocated",
        "Share",
        "Exclusive",
    ]
    rows = [
        [
            str(row["userId"]),
            row["displayName"],
            str(row["movies"]),
            format_bytes(row["movieBytes"]),
            str(row["series"]),
            str(row["seasons"]),
            format_bytes(row["tvBytes"]),
            str(row["files"]),
            format_bytes(row["logicalBytes"]),
            format_bytes(row["allocatedBytes"]),
            f"{row['allocatedPercent']:.1f}%",
            format_bytes(row["exclusiveBytes"]),
        ]
        for row in report["users"]
    ]
    widths = [
        max(len(headers[index]), *(len(row[index]) for row in rows))
        for index in range(len(headers))
    ]
    right_aligned = {0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}

    def render_row(row):
        return "  ".join(
            value.rjust(widths[index])
            if index in right_aligned
            else value.ljust(widths[index])
            for index, value in enumerate(row)
        )

    lines = [render_row(headers), render_row(["-" * width for width in widths])]
    lines.extend(render_row(row) for row in rows)
    totals = report["totals"]
    unresolved = report["unresolved"]
    requests = report["requests"]
    lines.extend(
        [
            "",
            f"Distinct attributed storage: {format_bytes(totals['distinctBytes'])} "
            f"({format_bytes(totals['movieBytes'])} movies, "
            f"{format_bytes(totals['tvBytes'])} TV) across {totals['files']} files "
            f"({totals['sharedFiles']} shared)",
            f"Logical per-user total: {format_bytes(totals['logicalBytes'])}",
            f"Requests: {requests['scanned']} scanned, {requests['eligible']} eligible, "
            f"{requests['skipped']} skipped",
            "Unresolved: "
            f"{unresolved['moviesNotInRadarr']} movies absent from Radarr, "
            f"{unresolved['moviesWithoutFiles']} movies without files, "
            f"{unresolved['seriesNotInSonarr']} series absent from Sonarr, "
            f"{unresolved['seasonsWithoutFiles']} seasons without files",
            "",
            "Logical counts each file in full for every requester; Allocated splits shared "
            "files evenly; Exclusive includes files attributed to only one user.",
        ]
    )
    return "\n".join(lines)


def build_parser():
    parser = argparse.ArgumentParser(
        description=(
            "Report current Radarr movie-file and Sonarr requested-season storage "
            "attributable to Seerr users."
        )
    )
    parser.add_argument(
        "--json", action="store_true", help="Emit machine-readable JSON"
    )
    parser.add_argument(
        "--ssh-host",
        default="srvarr",
        help="Host on which to run the report (default: srvarr)",
    )
    parser.add_argument(
        "--local",
        action="store_true",
        help="Run locally instead of streaming the reporter to --ssh-host",
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
    parser.add_argument("--timeout", type=float, default=30.0)
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
        "--timeout",
        str(args.timeout),
    ]
    if args.json:
        remote_args.append("--json")
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
        raise ReportError("--page-size must be positive")
    if args.timeout <= 0:
        raise ReportError("--timeout must be positive")
    if not args.local:
        return dispatch_remote(args)
    report = build_report(args)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(render_table(report))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ReportError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
