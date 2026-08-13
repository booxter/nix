{ pkgs, ... }:
let
  arrAddress = "192.168.1.1";
  arrPort = 8686;
  apiKey = "integration-test-api-key";
  aiosqlitepool = pkgs.callPackage ../../pkgs/aiosqlitepool { };
  houndarr = pkgs.callPackage ../../nixos/_mixins/houndarr/package { inherit aiosqlitepool; };
  houndarrTools = pkgs.callPackage ../../nixos/_mixins/houndarr/tools { inherit houndarr; };
  credential = pkgs.writeText "houndarr-test-lidarr.xml" ''
    <Config><ApiKey>${apiKey}</ApiKey></Config>
  '';
  desired =
    {
      displayName,
      policy,
    }:
    pkgs.writeText "houndarr-test-reconcile.json" (
      builtins.toJSON {
        instances = [
          {
            key = "catalog";
            inherit displayName policy;
            interface = "lidarr";
            url = "http://lidarr.example.test:${toString arrPort}";
            enabled = true;
            credential = {
              name = "api-catalog";
              format = "xml-element";
              field = "ApiKey";
            };
          }
        ];
      }
    );
  initialConfiguration = desired {
    displayName = "Initial catalog";
    policy = null;
  };
  updatedConfiguration = desired {
    displayName = "Music catalog";
    policy = {
      batch_size = 7;
      cooldown_days = 5;
    };
  };
  fakeLidarr = pkgs.writeText "fake-lidarr.py" ''
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


    API_KEY = ${builtins.toJSON apiKey}


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.headers.get("X-Api-Key") != API_KEY:
                self.send_response(401)
                self.end_headers()
                return
            if self.path != "/api/v1/system/status":
                self.send_response(404)
                self.end_headers()
                return
            body = b'{"appName":"Lidarr","instanceName":"Test catalog","version":"3.1.0"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format, *args):
            pass


    ThreadingHTTPServer(("0.0.0.0", ${toString arrPort}), Handler).serve_forever()
  '';
  mkReconcileService = configuration: {
    serviceConfig = {
      Type = "oneshot";
      User = "houndarr";
      Group = "houndarr";
      LoadCredential = [ "api-catalog:${credential}" ];
      ExecStart = pkgs.lib.escapeShellArgs [
        (pkgs.lib.getExe' houndarrTools "houndarr-reconcile")
        "--data-dir"
        "/var/lib/houndarr"
        "--config"
        configuration
      ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "houndarr-reconcile";

  nodes = {
    arr = {
      networking.firewall.allowedTCPPorts = [ arrPort ];
      systemd.services.fake-lidarr = {
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python ${fakeLidarr}";
          Restart = "on-failure";
        };
      };
    };

    reconciler = {
      networking.hosts.${arrAddress} = [ "lidarr.example.test" ];
      users = {
        groups.houndarr = { };
        users.houndarr = {
          isSystemUser = true;
          group = "houndarr";
        };
      };
      systemd = {
        tmpfiles.rules = [ "d /var/lib/houndarr 0700 houndarr houndarr - -" ];
        services = {
          houndarr-reconcile-create = mkReconcileService initialConfiguration;
          houndarr-reconcile-update = mkReconcileService updatedConfiguration;
          houndarr-reconcile-idempotent = mkReconcileService updatedConfiguration;
        };
      };
    };
  };

  testScript = ''
    start_all()
    arr.wait_for_unit("fake-lidarr.service")
    arr.wait_for_open_port(${toString arrPort})
    reconciler.wait_for_unit("multi-user.target")

    reconciler.succeed("systemctl start houndarr-reconcile-create.service")
    reconciler.succeed(
        "journalctl -u houndarr-reconcile-create.service -o cat "
        "| grep -F 'Reconciled Houndarr instances: 1 changed.'"
    )

    reconciler.succeed("systemctl start houndarr-reconcile-update.service")
    reconciler.succeed(
        "journalctl -u houndarr-reconcile-update.service -o cat "
        "| grep -F 'Reconciled Houndarr instances: 1 changed.'"
    )

    reconciler.succeed("systemctl start houndarr-reconcile-idempotent.service")
    reconciler.succeed(
        "journalctl -u houndarr-reconcile-idempotent.service -o cat "
        "| grep -F 'Reconciled Houndarr instances: 0 changed.'"
    )
  '';
}
