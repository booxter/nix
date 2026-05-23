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
  enabledPrometheusMtlsEndpoints = lib.filterAttrs (_: endpoint: endpoint.enable) cfg.prometheusMtlsEndpoints;
  endpointSecretAttrName = endpointName: "prometheus-mtls-${endpointName}";
  endpointPortValues = map (endpoint: endpoint.port) (builtins.attrValues enabledPrometheusMtlsEndpoints);
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

      mtls = {
        enable = lib.mkEnableOption "mTLS protection for the Prometheus blackbox exporter";

        internalPort = lib.mkOption {
          type = lib.types.port;
          default = 19115;
          description = "Loopback-only port for the local blackbox exporter when fronted by the mTLS proxy.";
        };

        publicPort = lib.mkOption {
          type = lib.types.port;
          default = 9115;
          description = "LAN-visible port for the mTLS-wrapped blackbox exporter endpoint.";
        };
      };
    };

    prometheusMtlsEndpoints = lib.mkOption {
      type = with lib.types; attrsOf (submodule ({ name, ... }: {
        options = {
          enable = lib.mkEnableOption "mTLS-protected Prometheus scrape endpoint";

          listenAddress = lib.mkOption {
            type = str;
            default = "0.0.0.0";
            description = "Address for the mTLS endpoint to bind.";
          };

          port = lib.mkOption {
            type = port;
            description = "LAN-visible port for the mTLS endpoint.";
          };

          path = lib.mkOption {
            type = str;
            default = "/metrics";
            description = "HTTP path exposed by the mTLS endpoint.";
          };

          upstream = lib.mkOption {
            type = str;
            description = "Upstream URL that nginx proxies to after mTLS auth.";
          };

          openFirewall = lib.mkOption {
            type = bool;
            default = true;
            description = "Whether to open the firewall for the mTLS endpoint.";
          };

          serverName = lib.mkOption {
            type = str;
            default = config.host.dnsName;
            description = "Server name presented by the nginx vhost for this endpoint.";
          };

          secretPrefix = lib.mkOption {
            type = str;
            default = "prometheus/${name}";
            description = "Secret prefix containing server_crt and server_key for this endpoint.";
          };

          locationExtraConfig = lib.mkOption {
            type = lines;
            default = "";
            description = "Extra nginx location config for this endpoint.";
          };
        };
      }));
      default = { };
      description = "Additional nginx-fronted mTLS endpoints for remote Prometheus scrapes.";
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
          listenAddress =
            if cfg.blackbox.mtls.enable then "127.0.0.1" else cfg.blackbox.listenAddress;
          openFirewall = if cfg.blackbox.mtls.enable then false else cfg.blackbox.openFirewall;
          port = if cfg.blackbox.mtls.enable then cfg.blackbox.mtls.internalPort else 9115;
          configFile = (pkgs.formats.yaml { }).generate "blackbox.yml" {
            modules = blackboxModules;
          };
        };

        host.observability.client.prometheusMtlsEndpoints.blackbox = lib.mkIf (
          cfg.blackbox.enable && cfg.blackbox.mtls.enable
        ) {
          enable = true;
          listenAddress = cfg.blackbox.listenAddress;
          port = cfg.blackbox.mtls.publicPort;
          path = "/probe";
          upstream = "http://127.0.0.1:${toString cfg.blackbox.mtls.internalPort}/probe";
          openFirewall = cfg.blackbox.openFirewall;
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
      (lib.mkIf (enabledPrometheusMtlsEndpoints != { }) {
        assertions = [
          {
            assertion = (builtins.length endpointPortValues) == (builtins.length (lib.unique endpointPortValues));
            message = "host.observability.client.prometheusMtlsEndpoints must not reuse listen ports on the same host.";
          }
        ];

        sops.secrets = lib.mapAttrs' (
          endpointName: endpoint:
          lib.nameValuePair "${endpointSecretAttrName endpointName}-server-crt" {
            key = "${endpoint.secretPrefix}/server_crt";
            owner = "root";
            group = "root";
            mode = "0400";
            restartUnits = [ "nginx.service" ];
          }
        ) enabledPrometheusMtlsEndpoints
        // lib.mapAttrs' (
          endpointName: endpoint:
          lib.nameValuePair "${endpointSecretAttrName endpointName}-server-key" {
            key = "${endpoint.secretPrefix}/server_key";
            owner = "root";
            group = "root";
            mode = "0400";
            restartUnits = [ "nginx.service" ];
          }
        ) enabledPrometheusMtlsEndpoints;

        services.nginx = {
          enable = true;
          recommendedProxySettings = true;
          recommendedTlsSettings = true;
          virtualHosts = lib.mapAttrs' (
            endpointName: endpoint:
            lib.nameValuePair "prometheus-mtls-${endpointName}" {
              serverName = endpoint.serverName;
              onlySSL = true;
              listen = [
                {
                  addr = endpoint.listenAddress;
                  port = endpoint.port;
                  ssl = true;
                }
              ];
              sslCertificate = config.sops.secrets."${endpointSecretAttrName endpointName}-server-crt".path;
              sslCertificateKey = config.sops.secrets."${endpointSecretAttrName endpointName}-server-key".path;
              sslTrustedCertificate = internalPkiRootCaPath;
              extraConfig = ''
                ssl_client_certificate ${internalPkiRootCaPath};
                ssl_verify_client on;
              '';
              locations.${endpoint.path} = {
                proxyPass = endpoint.upstream;
                extraConfig = endpoint.locationExtraConfig;
              };
            }
          ) enabledPrometheusMtlsEndpoints;
        };

        networking.firewall.allowedTCPPorts = lib.unique (
          builtins.concatMap (
            endpoint: lib.optional endpoint.openFirewall endpoint.port
          ) (builtins.attrValues enabledPrometheusMtlsEndpoints)
        );

        systemd.services.nginx = {
          wants = [ "sops-install-secrets.service" ];
          after = [ "sops-install-secrets.service" ];
        };
      })
    ]
  );
}
