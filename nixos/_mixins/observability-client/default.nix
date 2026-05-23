{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.client;
  hostLabel = config.services.avahi.hostName;
  blackboxModules = import ../../../lib/prometheus-blackbox-modules.nix;
  internalPkiRootCaPath = ../../../common/_mixins/internal-pki/home-internal-pki-root-ca.crt;
  nodeExporterGroup = config.services.prometheus.exporters.node.group;
  nodeExporterUser = config.services.prometheus.exporters.node.user;
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

      mtls.enable = lib.mkEnableOption "mTLS protection for the Prometheus node exporter";
    };

    blackbox = {
      enable = lib.mkEnableOption "host-side blackbox exporter probes";

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address for the Prometheus blackbox exporter to bind.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to open the firewall for the Prometheus blackbox exporter.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
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

        # Optional blackbox exporter lets Prometheus run the same reachability
        # probes from other LAN nodes for WAN comparison.
        services.prometheus.exporters.blackbox = lib.mkIf cfg.blackbox.enable {
          enable = true;
          inherit (cfg.blackbox) listenAddress openFirewall;
          configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
            modules = blackboxModules;
          };
        };
      }
      (lib.mkIf cfg.nodeExporter.mtls.enable {
        sops.secrets.prometheusNodeExporterServerCrt = {
          key = "prometheus/node_exporter/server_crt";
          owner = nodeExporterUser;
          group = nodeExporterGroup;
          mode = "0400";
          restartUnits = [ "prometheus-node-exporter.service" ];
        };
        sops.secrets.prometheusNodeExporterServerKey = {
          key = "prometheus/node_exporter/server_key";
          owner = nodeExporterUser;
          group = nodeExporterGroup;
          mode = "0400";
          restartUnits = [ "prometheus-node-exporter.service" ];
        };

        sops.templates."node-exporter-web-config.yaml" = {
          owner = nodeExporterUser;
          group = nodeExporterGroup;
          mode = "0400";
          content = ''
            tls_server_config:
              cert_file: ${config.sops.secrets.prometheusNodeExporterServerCrt.path}
              key_file: ${config.sops.secrets.prometheusNodeExporterServerKey.path}
              client_auth_type: RequireAndVerifyClientCert
              client_ca_file: ${internalPkiRootCaPath}
          '';
          restartUnits = [ "prometheus-node-exporter.service" ];
        };

        services.prometheus.exporters.node.extraFlags = [
          "--web.config.file=${config.sops.templates."node-exporter-web-config.yaml".path}"
        ];

        systemd.services.prometheus-node-exporter = {
          wants = [ "sops-install-secrets.service" ];
          after = [ "sops-install-secrets.service" ];
        };
      })
    ]
  );
}
