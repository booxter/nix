{
  config,
  lib,
  ...
}:
let
  cfg = config.host.observability.client;
in
{
  imports = [ ../../../common/_mixins/observability-client/node-exporter.nix ];

  options.host.observability.client = {
    enable = lib.mkEnableOption "host-side observability client services";

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
                  description = "Secret prefix containing client_crt_unencrypted and client_key for this client identity.";
                };

                commonName = lib.mkOption {
                  type = str;
                  default = "${name}.${config.networking.hostName}";
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

      host.observability.lanWan.enable = lib.mkDefault config.host.isDesktop;
      host.observability.thermal.enable = lib.mkDefault (!config.host.isWork);
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          host.observability.client.nodeExporter = {
            serviceUser = config.launchd.daemons.prometheus-node-exporter.serviceConfig.UserName;
            serviceGroup = config.launchd.daemons.prometheus-node-exporter.serviceConfig.GroupName;
          };

          services.prometheus.exporters.node = {
            enable = true;
            listenAddress = cfg.nodeExporter.listenAddress;
            disabledCollectors = lib.mkIf config.host.observability.thermal.enable [ "thermal" ];
          };
        }
      ]
    ))
  ];
}
