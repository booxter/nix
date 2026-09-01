from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length) if content_length else b""
        with Path("/tmp/fake-oauth2-backend.log").open("a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path} body={len(body)}\n")

        if self.path == "/native-401":
            self.send_response(401)
            self.end_headers()
            return

        self.send_response(200)
        if self.path == "/spoof-marker":
            self.send_header("X-SSO-Reauth", "spoofed")
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        if self.command != "HEAD":
            user = self.headers.get("X-User", "")
            self.wfile.write(f"{self.command} {self.path} user={user}\n".encode())

    do_GET = handle_request
    do_HEAD = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request

    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", 9000), Handler).serve_forever()
