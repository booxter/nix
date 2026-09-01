from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def handle_request(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length) if content_length else b""
        redirect = self.headers.get("X-Auth-Request-Redirect", "")
        with open("/tmp/fake-oauth2-proxy.log", "a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path} body={len(body)} redirect={redirect}\n")

        if self.path == "/oauth2/auth":
            if "session=valid" in self.headers.get("Cookie", ""):
                self.send_response(202)
                self.send_header("X-Auth-Request-User", "test-user")
                self.send_header("X-Auth-Request-Email", "test@example.invalid")
            else:
                self.send_response(401)
            self.end_headers()
            return

        if self.path == "/oauth2/start":
            self.send_response(302)
            self.send_header("Location", "https://idp.example.invalid/authorize")
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()

    do_GET = handle_request
    do_HEAD = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request

    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", 4180), Handler).serve_forever()
