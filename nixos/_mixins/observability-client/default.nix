{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.client;
  hostLabel = config.services.avahi.hostName;
in
{
  options.host.observability.client = {
    enable = lib.mkEnableOption "host-side observability client services";

    lokiWriteUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Loki push endpoint URL for journal log shipping.";
    };

    nodeExporter = {
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address for the Prometheus node exporter to bind.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to open the firewall for the Prometheus node exporter.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Node exporter exposes host-level Linux metrics for Prometheus to scrape.
    services.prometheus.exporters.node = {
      enable = true;
      inherit (cfg.nodeExporter) listenAddress openFirewall;
      enabledCollectors = [
        "processes"
        "systemd"
      ];
    };

    # Alloy reads the local journal and ships those logs into Loki.
    services.alloy = lib.mkIf (cfg.lokiWriteUrl != null) {
      enable = true;
      configPath = pkgs.writeText "config.alloy" ''
        loki.write "default" {
          endpoint {
            url = "${cfg.lokiWriteUrl}"
          }
        }

        loki.relabel "journal" {
          forward_to = []

          rule {
            source_labels = ["__journal__hostname"]
            target_label  = "node_hostname"
          }

          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "systemd_unit"
          }

          rule {
            source_labels = ["__journal_priority_keyword"]
            target_label  = "level"
          }
        }

        loki.source.journal "read" {
          forward_to    = [loki.write.default.receiver]
          relabel_rules = loki.relabel.journal.rules
          max_age       = "12h"
          labels = {
            job  = "systemd-journal",
            host = "${hostLabel}",
          }
        }
      '';
    };
  };
}
