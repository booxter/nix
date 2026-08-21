{ pkgs, ... }:
let
  fixtures = ./houndarr-reconcile;
  arrAddress = "192.168.1.1";
  arrPort = 9443;
  apiKey = "integration-test-api-key";
  serverName = "lidarr.example.test";
  credential = pkgs.writeText "houndarr-test-lidarr.xml" ''
    <Config><ApiKey>${apiKey}</ApiKey></Config>
  '';
  testPki = import ./lib/tls-pki.nix { inherit pkgs serverName; };
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
          ExecStart = pkgs.lib.escapeShellArgs [
            "${pkgs.python3}/bin/python"
            "${fixtures}/fake-lidarr.py"
            "--api-key"
            apiKey
            "--certificate"
            "${testPki}/server.crt"
            "--key"
            "${testPki}/server.key"
            "--port"
            (toString arrPort)
          ];
          Restart = "on-failure";
        };
      };
    };

    reconciler =
      { lib, ... }:
      {
        imports = [
          ../../nixos/_mixins/houndarr/reconciliation.nix
          ../../nixos/_mixins/web/api.nix
          ../../nixos/_mixins/web/options.nix
        ];

        networking.hosts.${arrAddress} = [ serverName ];
        security.pki.certificateFiles = [ "${testPki}/ca.crt" ];
        services.nginx.enable = true;

        host = {
          houndarr = {
            enable = true;
            instances.catalog = {
              api = "catalog";
              displayName = "Initial catalog";
            };
          };
          web = {
            services.lidarr = {
              upstream = "http://127.0.0.1:8686";
              internal.serverName = serverName;
            };
            api.catalog = {
              service = "lidarr";
              interface = "lidarr";
              allowedCidrs = [ "${arrAddress}/32" ];
              authentication.apiKey = {
                source = "${credential}";
                field = "ApiKey";
              };
            };
          };
        };

        specialisation.updated.configuration.host.houndarr.instances.catalog = {
          displayName = lib.mkForce "Music catalog";
          policy = lib.mkForce {
            missing = {
              batchSize = 7;
              cooldownDays = 5;
            };
          };
        };
      };
  };

  testScript = ''
    UPDATED_SYSTEM = "/run/current-system/specialisation/updated"
  ''
  + builtins.readFile "${fixtures}/test.py";
}
