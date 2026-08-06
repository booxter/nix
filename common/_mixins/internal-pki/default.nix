{ config, lib, ... }:
let
  rootConfig = config;
  cfg = config.host.internalPki;
  enabledClients = lib.filterAttrs (_: client: client.enable) cfg.clients;
  secretBaseName =
    clientName: materializationName:
    "internal-pki-client-${clientName}"
    + lib.optionalString (materializationName != "default") "-${materializationName}";
  materializationType =
    clientName:
    lib.types.submodule (
      { name, ... }:
      let
        baseName = secretBaseName clientName name;
      in
      {
        options = {
          owner = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Owner for the materialized client certificate and key.";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Group for the materialized client certificate and key.";
          };

          mode = lib.mkOption {
            type = lib.types.str;
            default = "0400";
            description = "Mode for the materialized client certificate and key.";
          };

          restartUnits = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Units restarted when this client certificate changes.";
          };

          certificateSecretName = lib.mkOption {
            type = lib.types.str;
            default = "${baseName}-crt";
            readOnly = true;
            internal = true;
            description = "SOPS secret attribute containing the materialized client certificate.";
          };

          keySecretName = lib.mkOption {
            type = lib.types.str;
            default = "${baseName}-key";
            readOnly = true;
            internal = true;
            description = "SOPS secret attribute containing the materialized client private key.";
          };
        };
      }
    );
  mkClientSecret =
    materialization: key:
    {
      inherit (materialization) owner group mode;
      inherit key;
    }
    // lib.optionalAttrs config.host.isLinux {
      restartUnits = materialization.restartUnits;
    };
in
{
  options.host.internalPki = {
    rootCaCertificate = lib.mkOption {
      type = lib.types.path;
      default = ./home-internal-pki-root-ca.crt;
      readOnly = true;
      internal = true;
      description = "Root CA certificate for the home internal PKI.";
    };

    clients = lib.mkOption {
      type =
        with lib.types;
        attrsOf (
          submodule (
            { name, config, ... }:
            {
              options = {
                enable = lib.mkEnableOption "internal PKI client identity";

                category = lib.mkOption {
                  type = enum [
                    "internal"
                    "observability"
                  ];
                  description = "Certificate issuance workflow that owns this client identity.";
                };

                secretPrefix = lib.mkOption {
                  type = str;
                  default =
                    if config.category == "observability" then
                      "prometheus/clients/${name}"
                    else
                      "internal_https/clients/${name}";
                  description = "SOPS key prefix containing client_crt_unencrypted and client_key for this client identity.";
                };

                commonName = lib.mkOption {
                  type = str;
                  default = "${name}.${rootConfig.networking.hostName}";
                  description = "Leaf certificate common name to issue for this client identity.";
                };

                sans = lib.mkOption {
                  type = listOf str;
                  default = [ ];
                  description = "Optional SANs for this client certificate.";
                };

                materializations = lib.mkOption {
                  type = attrsOf (materializationType name);
                  default = {
                    default = { };
                  };
                  description = "Runtime certificate and key copies for consumers of this identity.";
                };
              };
            }
          )
        );
      default = { };
      description = "Internal PKI client identities used by services on this host.";
    };
  };

  config.security.pki.certificateFiles = lib.mkIf (!config.host.isWork) [
    config.host.internalPki.rootCaCertificate
  ];

  config.sops.secrets = lib.concatMapAttrs (
    clientName: client:
    lib.concatMapAttrs (
      materializationName: materialization:
      let
        baseName = secretBaseName clientName materializationName;
      in
      {
        "${baseName}-crt" = mkClientSecret materialization "${client.secretPrefix}/client_crt_unencrypted";
        "${baseName}-key" = mkClientSecret materialization "${client.secretPrefix}/client_key";
      }
    ) client.materializations
  ) enabledClients;
}
