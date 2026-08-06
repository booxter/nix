{ pkgs, ... }:
let
  testPki = pkgs.runCommand "blackbox-test-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir "$out"

    openssl req -x509 -newkey rsa:2048 -nodes \
      -subj /CN=blackbox-test-ca \
      -keyout "$out/ca.key" \
      -out "$out/ca.crt" \
      -days 1

    openssl req -new -newkey rsa:2048 -nodes \
      -subj /CN=blackbox \
      -addext "subjectAltName=DNS:blackbox" \
      -addext "extendedKeyUsage=serverAuth" \
      -keyout "$out/server.key" \
      -out "$out/server.csr"
    openssl x509 -req \
      -in "$out/server.csr" \
      -CA "$out/ca.crt" \
      -CAkey "$out/ca.key" \
      -CAcreateserial \
      -copy_extensions copy \
      -out "$out/server.crt" \
      -days 1

    openssl req -new -newkey rsa:2048 -nodes \
      -subj /CN=prometheus-test \
      -addext "extendedKeyUsage=clientAuth" \
      -keyout "$out/client.key" \
      -out "$out/client.csr"
    openssl x509 -req \
      -in "$out/client.csr" \
      -CA "$out/ca.crt" \
      -CAkey "$out/ca.key" \
      -CAcreateserial \
      -copy_extensions copy \
      -out "$out/client.crt" \
      -days 1
  '';
  localExporter = "http://127.0.0.1:19115";
  targetHttpPort = 18080;
  targetDnsPort = 1053;
in
pkgs.testers.runNixOSTest {
  name = "blackbox";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ ../../nixos/_mixins/observability ];

      options = {
        host = {
          internalPki.rootCaCertificate = lib.mkOption {
            type = lib.types.path;
            default = "${testPki}/ca.crt";
          };

          internalPki.clients = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };

          isProxmox = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };

          isWork = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };

          observability.lanWan = {
            enable = lib.mkEnableOption "test LAN/WAN accounting";
            mode = lib.mkOption {
              type = lib.types.enum [
                "host-local"
                "interface-path"
              ];
              default = "interface-path";
            };
          };
        };

        sops = {
          secrets = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }:
                {
                  freeformType = lib.types.attrsOf lib.types.anything;
                  options.path = lib.mkOption {
                    type = lib.types.str;
                    default = "/run/secrets/${name}";
                  };
                }
              )
            );
            default = { };
          };

        };
      };

      config = {
        _module.args = {
          hostInventory = {
            site.lan.domain = "example.invalid";
            toNixosHostCertificateDnsNames = _: [ "blackbox" ];
          };
          hostSpec = { };
        };

        networking = {
          hostName = "blackbox";
          firewall = {
            enable = true;
            allowedTCPPorts = [ targetHttpPort ];
            allowedUDPPorts = [ targetDnsPort ];
          };
        };

        host.observability = {
          enable = true;
          loki.writeUrl = null;
          loki.mtls.enable = false;
          nodeExporter.mtls.enable = false;
          blackbox = {
            remote.enable = true;
            modules.http_created = {
              http = {
                preferred_ip_protocol = "ip4";
                valid_status_codes = [ 201 ];
              };
              prober = "http";
              timeout = "5s";
            };
          };
        };

        host.internalPki.clients.loki.enable = false;

        sops.secrets = {
          "prometheus-mtls-blackbox-server-crt".path = "${testPki}/server.crt";
          "prometheus-mtls-blackbox-server-key".path = "${testPki}/server.key";
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
    import json
    import shlex
    import time


    LOCAL_EXPORTER = "${localExporter}"
    REMOTE_EXPORTER = "https://blackbox:9115"
    TARGET_HTTP = "http://127.0.0.1:${toString targetHttpPort}"
    TEST_PKI = "${testPki}"


    def command(arguments):
        return " ".join(shlex.quote(str(argument)) for argument in arguments)


    def metric_value(metrics, name):
        matches = [
            line for line in metrics.splitlines()
            if line.startswith(f"{name} ")
        ]
        assert len(matches) == 1, (name, metrics)
        return float(matches[0].split()[1])


    def probe(module, target, *, remote=False, authenticated=True):
        exporter = REMOTE_EXPORTER if remote else LOCAL_EXPORTER
        arguments = [
            "curl", "--fail", "--silent", "--show-error", "--get",
            f"{exporter}/probe",
            "--data-urlencode", f"module={module}",
            "--data-urlencode", f"target={target}",
        ]
        if remote:
            arguments += [
                "--cacert", f"{TEST_PKI}/ca.crt",
                "--resolve", "blackbox:9115:127.0.0.1",
            ]
            if authenticated:
                arguments += [
                    "--cert", f"{TEST_PKI}/client.crt",
                    "--key", f"{TEST_PKI}/client.key",
                ]
        return machine.succeed(command(arguments))


    def assert_probe(module, target, expected, **kwargs):
        metrics = probe(module, target, **kwargs)
        actual = metric_value(metrics, "probe_success")
        assert actual == float(expected), (
            f"{module} probing {target}: expected {expected}, got {actual}",
            metrics,
        )


    def prometheus_query(query):
        output = machine.succeed(command([
            "curl", "--fail", "--silent", "--show-error", "--get",
            "http://127.0.0.1:9090/api/v1/query",
            "--data-urlencode", f"query={query}",
        ]))
        response = json.loads(output)
        assert response["status"] == "success", response
        return response["data"]["result"]


    def wait_for_prometheus_value(query, expected):
        deadline = time.monotonic() + 30
        last_result = []
        while time.monotonic() < deadline:
            last_result = prometheus_query(query)
            if (
                len(last_result) == 1
                and float(last_result[0]["value"][1]) == float(expected)
            ):
                return
            time.sleep(1)
        raise AssertionError((query, expected, last_result))


    start_all()
    machine.wait_for_unit("prometheus-blackbox-exporter.service")
    machine.wait_for_unit("nginx.service")
    machine.wait_for_unit("dnsmasq.service")
    machine.wait_for_unit("prometheus.service")
    for port in (9115, 9090, ${toString targetHttpPort}, ${toString targetDnsPort}):
        machine.wait_for_open_port(port)

    with subtest("HTTP status modules express their acceptance policy"):
        assert_probe("http_service", f"{TARGET_HTTP}/ok", 1)
        assert_probe("http_service", f"{TARGET_HTTP}/conflict", 0)
        assert_probe("http_service_409", f"{TARGET_HTTP}/conflict", 1)
        assert_probe("http_service_409", f"{TARGET_HTTP}/ok", 0)
        assert_probe("http_created", f"{TARGET_HTTP}/created", 1)

    with subtest("TCP module distinguishes open and closed ports"):
        assert_probe("tcp_connect_ipv4", "127.0.0.1:${toString targetHttpPort}", 1)
        assert_probe("tcp_connect_ipv4", "127.0.0.1:18081", 0)

    with subtest("DNS module queries the configured UDP resolver"):
        assert_probe("dns_udp", "127.0.0.1:${toString targetDnsPort}", 1)

    with subtest("ICMP module probes through its raw-socket capability"):
        assert_probe("icmp_ipv4", "127.0.0.1", 1)

    with subtest("remote endpoint requires a trusted client certificate"):
        assert_probe("http_service", f"{TARGET_HTTP}/ok", 1, remote=True)
        unauthenticated = [
            "curl", "--fail", "--silent", "--show-error", "--get",
            f"{REMOTE_EXPORTER}/probe",
            "--data-urlencode", "module=http_service",
            "--data-urlencode", f"target={TARGET_HTTP}/ok",
            "--cacert", f"{TEST_PKI}/ca.crt",
            "--resolve", "blackbox:9115:127.0.0.1",
        ]
        machine.fail(command(unauthenticated))

    with subtest("Prometheus consumes blackbox probe metrics"):
        wait_for_prometheus_value('probe_success{job="blackbox-test"}', 1)
  '';
}
