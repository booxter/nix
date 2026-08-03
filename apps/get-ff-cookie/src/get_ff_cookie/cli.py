import argparse
import io
import sqlite3
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from dataclasses import dataclass
from http.cookiejar import Cookie
from pathlib import Path
from typing import Protocol, TextIO, cast
from urllib.parse import urlsplit

from gallery_dl import cookies as gallery_cookies  # type: ignore[import-untyped]
from gallery_dl import util as gallery_util


DEFAULT_DOMAIN = "instagram.com"


@dataclass(frozen=True)
class ExportRequest:
    domain: str
    profile: str | None
    container: str | None
    urls: tuple[str, ...]


class CookieExportError(Exception):
    def __init__(self, message: str, *, status: int = 1) -> None:
        super().__init__(message)
        self.status = status


class CookieExporter(Protocol):
    def export(self, request: ExportRequest, output: TextIO) -> int: ...


class CookieLibrary(Protocol):
    def load_firefox(
        self,
        *,
        domain: str,
        profile: str | None,
        container: str | None,
    ) -> Sequence[Cookie]: ...

    def write_netscape(self, output: TextIO, cookies: Sequence[Cookie]) -> None: ...


class GalleryDlCookieLibrary:
    def load_firefox(
        self,
        *,
        domain: str,
        profile: str | None,
        container: str | None,
    ) -> Sequence[Cookie]:
        loaded: object = gallery_cookies.load_cookies_firefox(
            "firefox",
            profile,
            container,
            domain,
        )
        if not isinstance(loaded, list) or not all(isinstance(cookie, Cookie) for cookie in loaded):
            raise CookieExportError("gallery-dl returned invalid Firefox cookie data")
        return cast(list[Cookie], loaded)

    def write_netscape(self, output: TextIO, cookies: Sequence[Cookie]) -> None:
        gallery_util.cookiestxt_store(output, cookies)


class BrowserCookieExporter:
    def __init__(self, library: CookieLibrary) -> None:
        self.library = library

    def export(self, request: ExportRequest, output: TextIO) -> int:
        try:
            cookies = self.library.load_firefox(
                domain=request.domain,
                profile=request.profile,
                container=request.container,
            )
            self.library.write_netscape(output, cookies)
        except (OSError, sqlite3.Error, ValueError) as error:
            raise CookieExportError(str(error)) from error
        return len(cookies)


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str]) -> int: ...


class SystemCommandRunner:
    def run(self, arguments: Sequence[str]) -> int:
        return subprocess.run(arguments, check=False, stdout=subprocess.DEVNULL).returncode


def _browser_spec(request: ExportRequest) -> str:
    specification = f"firefox/{request.domain}"
    if request.profile is not None:
        specification += f":{request.profile}"
    if request.container is not None:
        specification += f"::{request.container}"
    return specification


def _cookie_count(text: str) -> int:
    return sum(
        1
        for line in text.splitlines()
        if (stripped := line.lstrip()) and not stripped.startswith("#")
    )


class GalleryDlUrlCookieExporter:
    """Use gallery-dl's supported CLI when extractors must visit URLs."""

    def __init__(self, runner: CommandRunner) -> None:
        self.runner = runner

    def export(self, request: ExportRequest, output: TextIO) -> int:
        with tempfile.TemporaryDirectory(prefix="get-ff-cookie-") as directory:
            cookie_path = Path(directory) / "cookies.txt"
            status = self.runner.run(
                [
                    "gallery-dl",
                    "--config-ignore",
                    "--quiet",
                    "--cookies-from-browser",
                    _browser_spec(request),
                    "--cookies-export",
                    str(cookie_path),
                    "--simulate",
                    *request.urls,
                ]
            )
            if status != 0:
                raise CookieExportError(f"gallery-dl failed with status {status}", status=status)
            try:
                rendered = cookie_path.read_text(encoding="utf-8")
            except OSError as error:
                raise CookieExportError(
                    f"Unable to read gallery-dl cookie export: {error}"
                ) from error
            output.write(rendered)
            return _cookie_count(rendered)


def normalize_domain(value: str) -> str:
    candidate = value.strip()
    parsed = urlsplit(candidate if "://" in candidate else f"//{candidate}")
    if parsed.hostname is None:
        raise ValueError("Cookie domain must not be empty")
    return parsed.hostname


def _non_empty(value: str) -> str:
    if not value:
        raise argparse.ArgumentTypeError("must not be empty")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="get-ff-cookie",
        description="Export Firefox cookies in Netscape cookies.txt format to stdout.",
        epilog=(
            "Examples:\n"
            "  get-ff-cookie\n"
            "  get-ff-cookie instagram.com\n"
            "  get-ff-cookie --profile default-release instagram.com"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--domain", type=_non_empty, help=f"cookie domain (default: {DEFAULT_DOMAIN})"
    )
    parser.add_argument("--profile", type=_non_empty, help="Firefox profile name or path")
    parser.add_argument("--container", type=_non_empty, help="Firefox container name")
    parser.add_argument(
        "targets",
        nargs="*",
        metavar="DOMAIN_OR_URL",
        help="a cookie domain or URLs for gallery-dl to visit before export",
    )
    return parser


def _request(arguments: argparse.Namespace, parser: argparse.ArgumentParser) -> ExportRequest:
    targets = cast(list[str], arguments.targets)
    urls = tuple(target for target in targets if "://" in target)
    positional_domains = [target for target in targets if "://" not in target]
    explicit_domain = cast(str | None, arguments.domain)
    raw_domain = explicit_domain or (
        positional_domains[-1] if positional_domains else DEFAULT_DOMAIN
    )
    try:
        domain = normalize_domain(raw_domain)
    except ValueError as error:
        parser.error(str(error))
    return ExportRequest(
        domain=domain,
        profile=cast(str | None, arguments.profile),
        container=cast(str | None, arguments.container),
        urls=urls,
    )


def main(
    argv: Sequence[str] | None = None,
    *,
    browser_exporter: CookieExporter | None = None,
    url_exporter: CookieExporter | None = None,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    parser = _parser()
    request = _request(parser.parse_args(argv), parser)
    browser = browser_exporter or BrowserCookieExporter(GalleryDlCookieLibrary())
    url = url_exporter or GalleryDlUrlCookieExporter(SystemCommandRunner())

    print(f"Exporting Firefox cookies for {request.domain}...", file=stderr)
    rendered = io.StringIO()
    try:
        count = (url if request.urls else browser).export(request, rendered)
    except CookieExportError as error:
        print(error, file=stderr)
        return error.status
    if count == 0:
        print(
            f"No cookies were exported for {request.domain}; "
            "check that Firefox is logged in for that site.",
            file=stderr,
        )
        return 1
    stdout.write(rendered.getvalue())
    return 0
