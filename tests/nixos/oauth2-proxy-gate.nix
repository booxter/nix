{ inputs, pkgs, ... }:
let
  serverName = "test.example.invalid";
  testPki = import ./lib/tls-pki.nix { inherit pkgs serverName; };
  fakeOauth2Proxy = pkgs.writeText "fake-oauth2-proxy.py" ''
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


    class Handler(BaseHTTPRequestHandler):
        def handle_request(self):
            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length) if content_length else b""
            redirect = self.headers.get("X-Auth-Request-Redirect", "")
            with open("/tmp/fake-oauth2-proxy.log", "a", encoding="utf-8") as log:
                log.write(
                    f"{self.command} {self.path} body={len(body)} redirect={redirect}\n"
                )

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
  '';

  fakeBackend = pkgs.writeText "fake-oauth2-gated-backend.py" ''
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


    class Handler(BaseHTTPRequestHandler):
        def handle_request(self):
            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length) if content_length else b""
            with open("/tmp/fake-oauth2-backend.log", "a", encoding="utf-8") as log:
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
  '';
in
pkgs.testers.runNixOSTest {
  name = "oauth2-proxy-gate";

  containers.machine =
    { lib, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../../common/_mixins/hardware
        ../../common/_mixins/host/options.nix
        ../../common/_mixins/internal-pki
        ../../common/_mixins/network
        ../../nixos/_mixins/sso/oauth2-proxy-gate
        ../../nixos/_mixins/web/api.nix
        ../../nixos/_mixins/web/internal-https.nix
        ../../nixos/_mixins/web/local-model.nix
        ../../nixos/_mixins/web/options.nix
        ./lib/sops.nix
      ];

      config = {
        host.pki.authority = lib.mkForce {
          hostName = "test-authority";
          rootCaCertificate = "${testPki}/ca.crt";
        };

        host.network.lanDomain = "example.invalid";
        host.sso.providerHost = "provider";

        sops.placeholder.oauth2-proxy-gate-test-client-secret = "test-client-secret";

        host.web.services.test = {
          upstream = "http://127.0.0.1:9000";
          internal = {
            inherit serverName;
            clientAuth = "none";
          };
        };

        host.sso.oauth2ProxyGates.test = {
          displayName = "Test";
          externalOrigin = "https://test.example.invalid";
          groupClaim = "groups";
          allowedGroups = [ "test-users" ];
          internalHttpsServiceNames = [ "test" ];
        };

        testSupport.sops.sources = {
          internal-https-test-server-crt = "${testPki}/server.crt";
          internal-https-test-server-key = "${testPki}/server.key";
        };

        # The test supplies a deterministic fake auth endpoint instead of
        # starting oauth2-proxy and provisioning its credentials.
        systemd.services.oauth2-proxy-test.wantedBy = lib.mkForce [ ];

        systemd.services.fake-oauth2-proxy = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${fakeOauth2Proxy}";
        };

        systemd.services.fake-oauth2-backend = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python ${fakeBackend}";
        };

        environment.systemPackages = [ pkgs.curl ];
      };
    };

  testScript = ''
    import shlex


    SERVER_NAME = ${builtins.toJSON serverName}
    TEST_PKI = ${builtins.toJSON "${testPki}"}


    def request(path, method="GET", headers=None, data=None):
        headers = headers or {}
        args = [
            "curl",
            "-sS",
            "-o", "/tmp/response-body",
            "-D", "/tmp/response-headers",
            "-w", "%{http_code}",
            "-X", method,
            "--cacert", f"{TEST_PKI}/ca.crt",
            "--resolve", f"{SERVER_NAME}:443:127.0.0.1",
        ]
        for name, value in headers.items():
            args += ["-H", f"{name}: {value}"]
        if data is not None:
            args += ["--data-binary", data]
        args.append(f"https://{SERVER_NAME}{path}")
        status = machine.succeed(" ".join(shlex.quote(arg) for arg in args)).strip()
        raw_headers = machine.succeed("cat /tmp/response-headers")
        body = machine.succeed("cat /tmp/response-body")
        parsed_headers = {}
        for line in raw_headers.splitlines():
            if ":" in line:
                name, value = line.split(":", 1)
                parsed_headers[name.lower()] = value.strip()
        return int(status), parsed_headers, body


    def clear_logs():
        machine.succeed(
            "truncate -s 0 /tmp/fake-oauth2-proxy.log "
            "/tmp/fake-oauth2-backend.log"
        )


    def logs():
        return (
            machine.succeed("cat /tmp/fake-oauth2-proxy.log"),
            machine.succeed("cat /tmp/fake-oauth2-backend.log"),
        )


    def assert_reauth_401(response, htmx=False):
        status, headers, _ = response
        assert status == 401, response
        assert headers.get("x-sso-reauth") == "1", response
        assert headers.get("cache-control") == "no-store", response
        assert "location" not in headers, response
        if htmx:
            assert headers.get("hx-refresh") == "true", response
        else:
            assert "hx-refresh" not in headers, response


    start_all()
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(443)
    machine.wait_for_open_port(4180)
    machine.wait_for_open_port(9000)

    with subtest("valid session reaches the backend"):
        response = request("/library", headers={"Cookie": "session=valid"})
        assert response[0] == 200, response
        assert response[2] == "GET /library user=test-user\n", response

    with subtest("document navigation starts sign-in with a safe GET"):
        clear_logs()
        response = request(
            "/library?sort=new",
            headers={
                "Accept": "text/html",
                "Sec-Fetch-Mode": "navigate",
                "Sec-Fetch-Dest": "document",
            },
        )
        assert response[0] == 302, response
        assert response[1].get("location") == (
            "https://idp.example.invalid/authorize"
        ), response
        oauth_log, backend_log = logs()
        assert "GET /oauth2/start body=0 " in oauth_log, oauth_log
        assert (
            "redirect=https://test.example.invalid/library?sort=new" in oauth_log
        ), oauth_log
        assert backend_log == "", backend_log

    with subtest("HTML fallback works without Fetch Metadata"):
        response = request("/fallback", headers={"Accept": "text/html"})
        assert response[0] == 302, response

    with subtest("background fetch receives a marked 401"):
        clear_logs()
        response = request(
            "/api/items",
            headers={
                "Accept": "application/json",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Dest": "empty",
            },
        )
        assert_reauth_401(response)
        oauth_log, backend_log = logs()
        assert "/oauth2/start" not in oauth_log, oauth_log
        assert backend_log == "", backend_log

    with subtest("HTMX receives a refresh instruction"):
        response = request(
            "/fragment",
            headers={"Accept": "text/html", "HX-Request": "true"},
        )
        assert_reauth_401(response, htmx=True)

    with subtest("unsafe methods are neither redirected nor replayed"):
        navigation_headers = {
            "Accept": "text/html",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "document",
        }
        for method in ["POST", "PUT", "PATCH", "DELETE"]:
            clear_logs()
            response = request(
                "/api/mutate",
                method=method,
                headers=navigation_headers,
                data=f"secret-{method}",
            )
            assert_reauth_401(response)
            oauth_log, backend_log = logs()
            assert "/oauth2/start" not in oauth_log, (method, oauth_log)
            assert "secret" not in oauth_log, (method, oauth_log)
            assert backend_log == "", (method, backend_log)

    with subtest("non-document browser transports do not start sign-in"):
        transports = [
            {"Accept": "text/html", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "iframe"},
            {"Accept": "*/*", "Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Dest": "script"},
            {"Accept": "text/event-stream", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty"},
            {"Accept": "*/*", "Sec-Fetch-Mode": "websocket", "Sec-Fetch-Dest": "empty"},
        ]
        for headers in transports:
            assert_reauth_401(request("/transport", headers=headers))

    with subtest("session probe reports valid and expired sessions"):
        valid = request("/oauth2/session", headers={"Cookie": "session=valid"})
        assert valid[0] == 202, valid
        assert valid[1].get("cache-control") == "no-store", valid
        assert "x-sso-reauth" not in valid[1], valid
        assert_reauth_401(request("/oauth2/session"))

    with subtest("only the proxy can emit the reauth marker"):
        spoofed = request("/spoof-marker", headers={"Cookie": "session=valid"})
        assert spoofed[0] == 200, spoofed
        assert "x-sso-reauth" not in spoofed[1], spoofed

        native = request("/native-401", headers={"Cookie": "session=valid"})
        assert native[0] == 401, native
        assert "x-sso-reauth" not in native[1], native
  '';
}
