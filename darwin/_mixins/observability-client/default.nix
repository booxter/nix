{ config, lib, ... }:
let
  cfg = config.host.observability.client;
  nodeExporterMtls = import ../../../lib/prometheus-node-exporter-mtls.nix;
in
{
  options.host.observability.client = {
    enable = lib.mkEnableOption "host-side observability client services";

    nodeExporter = {
      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address for the Prometheus node exporter to bind.";
      };

      mtls.enable = lib.mkEnableOption "mTLS protection for the Prometheus node exporter";
    };

    mtlsClients = lib.mkOption {
      type =
        with lib.types;
        attrsOf (
          submodule (
            { name, ... }:
            {
              options = {
                enable = lib.mkEnableOption "mTLS client certificate for consuming protected internal endpoints";

                secretPrefix = lib.mkOption {
                  type = str;
                  default = "prometheus/clients/${name}";
                  description = "Secret prefix containing client_crt and client_key for this client identity.";
                };

                commonName = lib.mkOption {
                  type = str;
                  default = "${name}.${config.host.dnsName}";
                  description = "Leaf certificate common name to issue for this client identity.";
                };

                sans = lib.mkOption {
                  type = listOf str;
                  default = [ ];
                  description = "Optional SANs for this client certificate.";
                };
              };
            }
          )
        );
      default = { };
      description = "Host-local mTLS client identities used to consume protected internal endpoints.";
    };
  };

  config = lib.mkMerge [
    {
      host.observability.client = {
        enable = lib.mkDefault (!config.host.isWork);
        nodeExporter.mtls.enable = lib.mkDefault (!config.host.isWork);
      };

      host.observability.lanWan.enable = lib.mkDefault (!config.host.isWork);
      host.observability.thermal.enable = lib.mkDefault (!config.host.isWork);
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          users.users._prometheus-node-exporter.home = lib.mkForce "/private/var/lib/prometheus-node-exporter";

          services.prometheus.exporters.node = {
            enable = true;
            listenAddress = cfg.nodeExporter.listenAddress;
            disabledCollectors = lib.mkIf config.host.observability.thermal.enable [ "thermal" ];
          };
        }
        (lib.mkIf cfg.nodeExporter.mtls.enable (
          let
            nodeExporterDaemon = config.launchd.daemons.prometheus-node-exporter.serviceConfig;
            nodeExporterUser = nodeExporterDaemon.UserName;
            nodeExporterGroup = nodeExporterDaemon.GroupName;
          in
          {
            sops.secrets.prometheusNodeExporterServerCrt = {
              key = "${nodeExporterMtls.nodeExporterSecretPrefix}/server_crt";
              owner = nodeExporterUser;
              group = nodeExporterGroup;
              mode = "0400";
            };

            sops.secrets.prometheusNodeExporterServerKey = {
              key = "${nodeExporterMtls.nodeExporterSecretPrefix}/server_key";
              owner = nodeExporterUser;
              group = nodeExporterGroup;
              mode = "0400";
            };

            sops.templates."node-exporter-web-config.yaml" = {
              owner = nodeExporterUser;
              group = nodeExporterGroup;
              mode = "0400";
              content = nodeExporterMtls.mkNodeExporterWebConfig {
                certFile = config.sops.secrets.prometheusNodeExporterServerCrt.path;
                keyFile = config.sops.secrets.prometheusNodeExporterServerKey.path;
              };
            };

            services.prometheus.exporters.node.extraFlags = [
              "--web.config.file=${config.sops.templates."node-exporter-web-config.yaml".path}"
            ];
          }
        ))
      ]
    ))
  ];
}
