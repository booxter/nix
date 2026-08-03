import importlib.util
import os
import sys
from unittest import mock


def load_main():
    path = os.environ["OIDC_SYNTHETIC_PROBE_MAIN"]
    spec = importlib.util.spec_from_file_location("oidc_synthetic_probe", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


main = load_main()


class Response:
    status = 200
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def geturl(self):
        return "https://app.example.test/"

    def read(self):
        return b""


def request_headers(method):
    client = main.HttpClient(timeout=1)
    client.opener = mock.Mock()
    client.opener.open.return_value = Response()

    method(client, "https://app.example.test/")

    request = client.opener.open.call_args.args[0]
    return {name.lower(): value for name, value in request.header_items()}


def test_navigation_get_identifies_top_level_document():
    headers = request_headers(main.HttpClient.get_navigation)

    assert headers["accept"] == "text/html"
    assert headers["sec-fetch-mode"] == "navigate"
    assert headers["sec-fetch-dest"] == "document"


def test_api_get_does_not_claim_to_be_navigation():
    headers = request_headers(main.HttpClient.get)

    assert headers["accept"] == "*/*"
    assert "sec-fetch-mode" not in headers
    assert "sec-fetch-dest" not in headers


def test_searxng_probe_enters_application_as_navigation():
    class Client:
        def get_navigation(self, url):
            return main.HttpResponse(200, {}, b"", url)

        def get(self, _url):
            raise AssertionError("application entry used an API GET")

    metrics = main.ProbeMetrics.create()

    assert main.run_searxng_probe(
        Client(),
        metrics,
        "https://id.example.test/",
        "https://search.example.test/",
        True,
    )
    assert metrics.probe_ok["searxng"] == 1


def test_oidc_page_redirects_remain_navigations():
    callback = "http://127.0.0.1:9/callback"

    class Client:
        def __init__(self):
            self.navigation_urls = []

        def get_navigation(self, url):
            self.navigation_urls.append(url)
            return main.HttpResponse(
                302,
                {"Location": f"{callback}?code=expected&state=state"},
                b"",
                url,
            )

        def get(self, _url):
            raise AssertionError("OIDC page redirect used an API GET")

    client = Client()
    initial = main.HttpResponse(
        302,
        {"Location": "https://id.example.test/ui/oauth2"},
        b"",
        "https://search.example.test/oauth2/start",
    )

    code, status = main.follow_oidc_authorization(
        client,
        "https://id.example.test/",
        initial,
        callback,
        "state",
    )

    assert code == "expected"
    assert status == 302
    assert client.navigation_urls == ["https://id.example.test/ui/oauth2"]
