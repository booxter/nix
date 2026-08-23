{ inputs, pkgs, ... }:
let
  fixtures = ./blackbox;
  testPki = import ./lib/tls-pki.nix {
    clientName = "prometheus-test";
    inherit pkgs;
    serverName = "blackbox";
  };
  localExporter = "http://127.0.0.1:19115";
  targetHttpPort = 18080;
  targetDnsPort = 1053;
in
pkgs.testers.runNixOSTest {
  name = "blackbox";

  node.specialArgs.fleetInventory.observability.blackboxSources = [ "blackbox" ];

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        ../../nixos/_mixins/observability/blackbox
        ./lib/sops.nix
      ];

      config = {
        host.pki.authority = lib.mkForce {
          hostName = "test-authority";
          rootCaCertificate = "${testPki}/ca.crt";
        };

        networking = {
          hostName = "blackbox";
          firewall = {
            enable = true;
            allowedTCPPorts = [ targetHttpPort ];
            allowedUDPPorts = [ targetDnsPort ];
          };
        };

        host.network = {
          lanDomain = "example.invalid";
          certificateDnsNames = [ "blackbox" ];
        };

        host.observability = {
          blackbox.modules.http_created = {
            http = {
              preferred_ip_protocol = "ip4";
              valid_status_codes = [ 201 ];
            };
            prober = "http";
            timeout = "5s";
          };
        };

        testSupport.sops.sources = {
          prometheus-mtls-blackbox-server-crt = "${testPki}/server.crt";
          prometheus-mtls-blackbox-server-key = "${testPki}/server.key";
        };

        services = {
          dnsmasq = {
            enable = true;
            settings = {
              address = "/example.com/192.0.2.1";
              bind-interfaces = true;
              listen-address = "127.0.0.1";
              port = targetDnsPort;
            };
          };

          nginx.virtualHosts.blackbox-target = {
            listen = [
              {
                addr = "127.0.0.1";
                port = targetHttpPort;
              }
            ];
            locations = {
              "/ok".extraConfig = "return 200 'ok';";
              "/created".extraConfig = "return 201 'created';";
              "/conflict".extraConfig = "return 409 'conflict';";
            };
          };

          prometheus = {
            enable = true;
            listenAddress = "127.0.0.1";
            port = 9090;
            globalConfig.scrape_interval = "1s";
            scrapeConfigs = [
              {
                job_name = "blackbox-test";
                metrics_path = "/probe";
                params.module = [ "http_service" ];
                static_configs = [
                  {
                    targets = [ "http://127.0.0.1:${toString targetHttpPort}/ok" ];
                  }
                ];
                relabel_configs = [
                  {
                    source_labels = [ "__address__" ];
                    target_label = "__param_target";
                  }
                  {
                    source_labels = [ "__param_target" ];
                    target_label = "instance";
                  }
                  {
                    replacement = "127.0.0.1:19115";
                    target_label = "__address__";
                  }
                ];
              }
            ];
          };
        };

        environment.systemPackages = [ pkgs.curl ];
      };
    };

  testScript = ''
    LOCAL_EXPORTER = ${builtins.toJSON localExporter}
    TARGET_HTTP_PORT = ${toString targetHttpPort}
    TARGET_DNS_PORT = ${toString targetDnsPort}
    TEST_PKI = ${builtins.toJSON "${testPki}"}
  ''
  + builtins.readFile "${fixtures}/test.py";
}
