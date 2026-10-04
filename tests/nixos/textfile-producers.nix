{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "textfile-producers";

  nodes.machine = { config, lib, ... }: {
    imports = [
      ../../common/_mixins/observability/textfiles.nix
      ../../nixos/_mixins/observability/node-exporter.nix
      ../../nixos/_mixins/observability/textfile-producers.nix
    ];

    options.host.observability = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      server = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
      };
      nodeExporter = {
        serviceUser = lib.mkOption { type = lib.types.str; };
        serviceGroup = lib.mkOption { type = lib.types.str; };
        listenAddress = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
        };
        mtls.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
      };
    };
    options.sops.secrets = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };

    config = {
      host.observability.nodeExporter = {
        mtls.enable = false;
        textfile.periodicProducers.lifecycle-test = {
          description = "Publish a lifecycle test metric";
          interval = "1h";
          onBootSec = "1s";
          command = [
            "${pkgs.coreutils}/bin/install"
            "-m"
            "0644"
            (toString (pkgs.writeText "sample.prom" "test_configured_producer 1\n"))
            "${config.host.observability.nodeExporter.textfile.periodicProducers.lifecycle-test.directory}/sample.prom"
          ];
        };
      };

      specialisation.removed.configuration.host.observability.nodeExporter.textfile.periodicProducers =
        lib.mkForce
          { };
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("prometheus-node-exporter.service")
    machine.wait_until_succeeds("curl -sf localhost:9100/metrics | grep '^test_configured_producer 1$'")

    with subtest("shared parent is not scraped"):
        machine.succeed("echo 'test_orphaned_producer 1' > /var/lib/prometheus-node-exporter-textfile/orphan.prom")
        metrics = machine.succeed("curl -sf localhost:9100/metrics")
        assert "test_orphaned_producer" not in metrics

    with subtest("removing a producer stops its scrape without deleting its files"):
        machine.succeed("/run/current-system/specialisation/removed/bin/switch-to-configuration test")
        machine.wait_for_unit("prometheus-node-exporter.service")
        machine.succeed("test -f /var/lib/prometheus-node-exporter-textfile/lifecycle-test/sample.prom")
        metrics = machine.succeed("curl -sf localhost:9100/metrics")
        assert "test_configured_producer" not in metrics
        assert "test_orphaned_producer" not in metrics
  '';
}
