import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


parser = argparse.ArgumentParser()
parser.add_argument("--api-key", required=True)
parser.add_argument("--port", required=True, type=int)
arguments = parser.parse_args()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.headers.get("X-Api-Key") != arguments.api_key:
            self.send_response(401)
            self.end_headers()
            return

        path = urlsplit(self.path).path
        if path == "/api/v1/system/status":
            payload: object = {"version": "test"}
        elif path == "/api/v1/qualityprofile":
            payload = [{"id": 1, "name": "Lossless"}]
        elif path == "/api/v1/metadataprofile":
            payload = [{"id": 1, "name": "Standard"}]
        elif path.startswith("/api/v1/"):
            payload = []
        else:
            self.send_response(404)
            self.end_headers()
            return

        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler).serve_forever()
