import io
from collections.abc import Sequence
from http.cookiejar import Cookie
from pathlib import Path
from typing import TextIO

import pytest

from get_ff_cookie.cli import (
    BrowserCookieExporter,
    CookieExportError,
    ExportRequest,
    GalleryDlUrlCookieExporter,
    main,
    normalize_domain,
)


class FakeExporter:
    def __init__(
        self, *, count: int = 1, rendered: str = "cookies\n", error: CookieExportError | None = None
    ) -> None:
        self.count = count
        self.rendered = rendered
        self.error = error
        self.requests: list[ExportRequest] = []

    def export(self, request: ExportRequest, output: TextIO) -> int:
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        if self.count:
            output.write(self.rendered)
        return self.count


class FakeCookieLibrary:
    def __init__(self, cookies: Sequence[Cookie]) -> None:
        self.cookies = tuple(cookies)
        self.loads: list[tuple[str, str | None, str | None]] = []

    def load_firefox(
        self,
        *,
        domain: str,
        profile: str | None,
        container: str | None,
    ) -> Sequence[Cookie]:
        self.loads.append((domain, profile, container))
        return self.cookies

    def write_netscape(self, output: TextIO, cookies: Sequence[Cookie]) -> None:
        output.write(f"rendered {len(cookies)} cookies\n")


class FailingCookieLibrary:
    def load_firefox(
        self,
        *,
        domain: str,
        profile: str | None,
        container: str | None,
    ) -> Sequence[Cookie]:
        raise ValueError(f"cannot read {domain}")

    def write_netscape(self, output: TextIO, cookies: Sequence[Cookie]) -> None:
        raise AssertionError("unexpected cookie serialization")


class ExportingRunner:
    def __init__(self, *, status: int = 0, rendered: str = "") -> None:
        self.status = status
        self.rendered = rendered
        self.arguments: tuple[str, ...] = ()

    def run(self, arguments: Sequence[str]) -> int:
        self.arguments = tuple(arguments)
        if self.status == 0:
            output_path = Path(arguments[arguments.index("--cookies-export") + 1])
            output_path.write_text(self.rendered, encoding="utf-8")
        return self.status


class MissingExportRunner:
    def run(self, arguments: Sequence[str]) -> int:
        return 0


def cookie(name: str = "session") -> Cookie:
    return Cookie(
        version=0,
        name=name,
        value="secret",
        port=None,
        port_specified=False,
        domain=".example.com",
        domain_specified=True,
        domain_initial_dot=True,
        path="/",
        path_specified=True,
        secure=True,
        expires=None,
        discard=False,
        comment=None,
        comment_url=None,
        rest={},
    )


def invoke(
    arguments: Sequence[str],
    browser: FakeExporter,
    url: FakeExporter,
) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    status = main(
        arguments,
        browser_exporter=browser,
        url_exporter=url,
        stdout=stdout,
        stderr=stderr,
    )
    return status, stdout.getvalue(), stderr.getvalue()


def test_defaults_to_instagram_browser_export() -> None:
    browser = FakeExporter(rendered="cookie data\n")
    url = FakeExporter()

    status, stdout, stderr = invoke([], browser, url)

    assert status == 0
    assert stdout == "cookie data\n"
    assert "Exporting Firefox cookies for instagram.com" in stderr
    assert browser.requests == [ExportRequest("instagram.com", None, None, ())]
    assert url.requests == []


def test_explicit_domain_profile_container_and_urls_use_url_exporter() -> None:
    browser = FakeExporter()
    url = FakeExporter()

    status, _, _ = invoke(
        [
            "--domain",
            "https://Example.COM:443/path",
            "--profile",
            "default-release",
            "--container",
            "Personal",
            "https://example.com/feed",
        ],
        browser,
        url,
    )

    assert status == 0
    assert browser.requests == []
    assert url.requests == [
        ExportRequest(
            "example.com",
            "default-release",
            "Personal",
            ("https://example.com/feed",),
        )
    ]


def test_last_positional_domain_wins_without_consuming_urls() -> None:
    browser = FakeExporter()
    url = FakeExporter()

    status, _, _ = invoke(
        ["first.example", "https://first.example/feed", "second.example"],
        browser,
        url,
    )

    assert status == 0
    assert browser.requests == []
    assert url.requests == [
        ExportRequest(
            "second.example",
            None,
            None,
            ("https://first.example/feed",),
        )
    ]


def test_reports_empty_export_and_exporter_status() -> None:
    empty_status, empty_stdout, empty_stderr = invoke([], FakeExporter(count=0), FakeExporter())
    failed_status, _, failed_stderr = invoke(
        [],
        FakeExporter(error=CookieExportError("failed", status=7)),
        FakeExporter(),
    )

    assert empty_status == 1
    assert empty_stdout == ""
    assert "No cookies were exported" in empty_stderr
    assert failed_status == 7
    assert "failed" in failed_stderr


def test_browser_exporter_uses_cookie_library() -> None:
    library = FakeCookieLibrary((cookie(), cookie("other")))
    output = io.StringIO()
    request = ExportRequest("example.com", "profile", "container", ())

    count = BrowserCookieExporter(library).export(request, output)

    assert count == 2
    assert library.loads == [("example.com", "profile", "container")]
    assert output.getvalue() == "rendered 2 cookies\n"


def test_browser_exporter_reports_cookie_library_failure() -> None:
    with pytest.raises(CookieExportError, match="cannot read example.com"):
        BrowserCookieExporter(FailingCookieLibrary()).export(
            ExportRequest("example.com", None, None, ()),
            io.StringIO(),
        )


def test_url_exporter_preserves_gallery_dl_extractor_mode() -> None:
    rendered = "# Netscape HTTP Cookie File\n\n.example.com\tTRUE\t/\tTRUE\t0\tsession\tsecret\n"
    runner = ExportingRunner(rendered=rendered)
    request = ExportRequest(
        "example.com",
        "profile",
        "container",
        ("https://example.com/feed",),
    )
    output = io.StringIO()

    count = GalleryDlUrlCookieExporter(runner).export(request, output)

    assert count == 1
    assert output.getvalue() == rendered
    assert runner.arguments[:6] == (
        "gallery-dl",
        "--config-ignore",
        "--quiet",
        "--cookies-from-browser",
        "firefox/example.com:profile::container",
        "--cookies-export",
    )
    assert runner.arguments[-2:] == ("--simulate", "https://example.com/feed")


def test_url_exporter_propagates_gallery_dl_status() -> None:
    with pytest.raises(CookieExportError) as raised:
        GalleryDlUrlCookieExporter(ExportingRunner(status=9)).export(
            ExportRequest("example.com", None, None, ("https://example.com",)),
            io.StringIO(),
        )

    assert raised.value.status == 9


def test_url_exporter_requires_gallery_dl_output() -> None:
    with pytest.raises(CookieExportError, match="Unable to read gallery-dl cookie export"):
        GalleryDlUrlCookieExporter(MissingExportRunner()).export(
            ExportRequest("example.com", None, None, ("https://example.com",)),
            io.StringIO(),
        )


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("instagram.com", "instagram.com"),
        ("https://Example.COM:8443/path", "example.com"),
        ("instagram.com/path", "instagram.com"),
    ],
)
def test_normalizes_domains(value: str, expected: str) -> None:
    assert normalize_domain(value) == expected


def test_rejects_empty_domain() -> None:
    with pytest.raises(ValueError, match="must not be empty"):
        normalize_domain("")
