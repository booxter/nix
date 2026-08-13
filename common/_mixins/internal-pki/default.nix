{
  config,
  lib,
  outputs,
  ...
}:
let
  rootConfig = config;
  cfg = config.host.pki;
  enabledClients = lib.filterAttrs (_: client: client.enable) cfg.clients;
  managedCertificateType = lib.types.submodule {
    options = {
      category = lib.mkOption {
        type = lib.types.enum [
          "internal_https_server"
          "internal_https_client"
          "observability_endpoint_server"
          "observability_client"
        ];
        description = "Managed certificate category used by rotation and monitoring.";
      };
      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Certificate name within its host and category.";
      };
      secretPrefix = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SOPS key prefix containing the certificate.";
      };
      certificateField = lib.mkOption {
        type = lib.types.enum [
          "client_crt_unencrypted"
          "server_crt_unencrypted"
        ];
        description = "Certificate field below the SOPS key prefix.";
      };
    };
  };
  realmAuthorityType = lib.types.submodule {
    options = {
      realm = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Realm served by this authority.";
      };
      hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Host providing the realm's internal PKI authority.";
      };
      rootCaCertificate = lib.mkOption {
        type = lib.types.path;
        description = "Root CA certificate published by the realm authority.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "HTTPS port of the realm authority API.";
      };
      rootsPath = lib.mkOption {
        type = lib.types.str;
        description = "Realm authority API path serving the trusted root bundle.";
      };
      url = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Resolved realm authority API URL.";
      };
      provisioner = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Smallstep provisioner used for realm leaf issuance.";
      };
      leafLifetimeDays = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Lifetime of leaf certificates issued by this authority.";
      };
    };
  };
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
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
  options.host.pki = {
    role = lib.mkOption {
      type = with lib.types; nullOr (enum [ "authority" ]);
      default = null;
      description = "Realm PKI role claimed by this host.";
    };

    authority = {
      displayName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "${config.host.realm} Internal PKI";
        description = "Human-readable name for the realm certificate authority.";
      };

      rootCaCertificate = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = "Root CA certificate published by this authority.";
      };

      api = {
        port = lib.mkOption {
          type = lib.types.port;
          default = 8443;
          description = "HTTPS port of the certificate authority API.";
        };

        rootsPath = lib.mkOption {
          type = lib.types.str;
          default = "/roots.pem";
          description = "Certificate authority API path serving the trusted root bundle.";
        };

        url = lib.mkOption {
          type = lib.types.str;
          default = "https://${config.networking.hostName}.${config.host.network.lanDomain}:${toString cfg.authority.api.port}";
          readOnly = true;
          internal = true;
          description = "Resolved certificate authority API URL.";
        };
      };

      provisioner = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "bootstrap@${config.host.network.lanDomain}";
        description = "Smallstep provisioner used for realm leaf issuance.";
      };

      leafLifetimeDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 180;
        description = "Lifetime of leaf certificates issued by this authority.";
      };

    };

    realmAuthority = lib.mkOption {
      type = with lib.types; nullOr realmAuthorityType;
      default = model.realmAuthority;
      readOnly = true;
      internal = true;
      description = "Internal PKI authority discovered for this host's realm.";
    };

    rootCaCertificate = lib.mkOption {
      type = with lib.types; nullOr path;
      default = if model.realmAuthority == null then null else model.realmAuthority.rootCaCertificate;
      readOnly = true;
      internal = true;
      description = "Root CA certificate for the realm's internal PKI.";
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

    managedCertificates = lib.mkOption {
      type = lib.types.listOf managedCertificateType;
      default = [ ];
      internal = true;
      description = "Normalized repository-managed certificates owned by this host configuration.";
    };
  };

  config = {
    host.pki.managedCertificates = lib.mapAttrsToList (name: client: {
      category =
        if client.category == "observability" then "observability_client" else "internal_https_client";
      inherit name;
      inherit (client) secretPrefix;
      certificateField = "client_crt_unencrypted";
    }) enabledClients;

    assertions = import ./assertions.nix {
      inherit
        config
        enabledClients
        lib
        model
        ;
    };

    security.pki.certificateFiles = lib.optionals (cfg.rootCaCertificate != null) [
      cfg.rootCaCertificate
    ];

    sops.secrets = lib.concatMapAttrs (
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
  };
}
