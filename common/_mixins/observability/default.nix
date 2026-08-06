{ config, lib, ... }:
{
  imports = [ ./node-exporter.nix ];

  options.host.observability = {
    enable = lib.mkEnableOption "host-side observability services";

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

  config.host.observability.enable = lib.mkDefault (!config.host.isWork);
}
