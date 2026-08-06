{ config, lib, ... }:
let
  cfg = config.host.internalHttps;
  enabledClients = lib.filterAttrs (_: client: client.enable) cfg.mtlsClients;
  secretAttrName = clientName: "internal-https-client-${clientName}";
  mkClientSecret =
    client: key:
    {
      inherit (client) owner group mode;
      inherit key;
    }
    // lib.optionalAttrs config.host.isLinux {
      restartUnits = client.restartUnits;
    };
in
{
  options.host = {
    internalPki.rootCaCertificate = lib.mkOption {
      type = lib.types.path;
      default = ./home-internal-pki-root-ca.crt;
      readOnly = true;
      internal = true;
      description = "Root CA certificate for the home internal PKI.";
    };

    internalHttps.mtlsClients = lib.mkOption {
      type =
        with lib.types;
        attrsOf (
          submodule (
            { name, ... }:
            {
              options = {
                enable = lib.mkEnableOption "internal HTTPS mTLS client identity";

                secretPrefix = lib.mkOption {
                  type = str;
                  default = "internal_https/clients/${name}";
                  description = "SOPS key prefix containing client_crt_unencrypted and client_key for this client identity.";
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

                owner = lib.mkOption {
                  type = str;
                  default = "root";
                  description = "Owner for generated client certificate and key secret files.";
                };

                group = lib.mkOption {
                  type = str;
                  default = "root";
                  description = "Group for generated client certificate and key secret files.";
                };

                mode = lib.mkOption {
                  type = str;
                  default = "0400";
                  description = "Mode for generated client certificate and key secret files.";
                };

                restartUnits = lib.mkOption {
                  type = listOf str;
                  default = [ ];
                  description = "Units restarted when this client certificate changes.";
                };
              };
            }
          )
        );
      default = { };
      description = "Internal HTTPS mTLS client identities used by services on this host.";
    };
  };

  config.security.pki.certificateFiles = lib.mkIf (!config.host.isWork) [
    config.host.internalPki.rootCaCertificate
  ];

  config.sops.secrets = lib.concatMapAttrs (clientName: client: {
    "${secretAttrName clientName}-crt" =
      mkClientSecret client "${client.secretPrefix}/client_crt_unencrypted";
    "${secretAttrName clientName}-key" = mkClientSecret client "${client.secretPrefix}/client_key";
  }) enabledClients;
}
