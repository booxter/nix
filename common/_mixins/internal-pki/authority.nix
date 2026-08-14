{ config, lib, ... }:
let
  rootConfig = config;
  authorityType = lib.types.submodule (
    { config, ... }:
    {
      options = {
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
          default = 8443;
          description = "HTTPS port of the realm authority API.";
        };
        rootsPath = lib.mkOption {
          type = lib.types.str;
          default = "/roots.pem";
          description = "Realm authority API path serving the trusted root bundle.";
        };
        url = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "https://${config.hostName}.${rootConfig.host.network.lanDomain}:${toString config.port}";
          readOnly = true;
          internal = true;
          description = "Resolved realm authority API URL.";
        };
        provisioner = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "bootstrap@${rootConfig.host.network.lanDomain}";
          description = "Smallstep provisioner used for realm leaf issuance.";
        };
        leafLifetimeDays = lib.mkOption {
          type = lib.types.ints.positive;
          default = 180;
          description = "Lifetime of leaf certificates issued by this authority.";
        };
        displayName = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "${rootConfig.host.realm} Internal PKI";
          description = "Human-readable name for the realm certificate authority.";
        };
      };
    }
  );
in
{
  options.host.pki.authority = lib.mkOption {
    type = with lib.types; nullOr authorityType;
    default = null;
    description = "Internal PKI authority policy for this host's realm.";
  };

  config.security.pki.certificateFiles = lib.optionals (config.host.pki.authority != null) [
    config.host.pki.authority.rootCaCertificate
  ];
}
