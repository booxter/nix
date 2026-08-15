{ config, lib, ... }:
let
  authorityType = lib.types.submodule {
    options = {
      hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Host providing the realm's internal PKI authority.";
      };
      rootCaCertificate = lib.mkOption {
        type = lib.types.path;
        description = "Root CA certificate published by the realm authority.";
      };
    };
  };
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
