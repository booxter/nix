{ lib, ... }:
let
  mailerType = lib.types.submodule {
    options = {
      relayHost = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SMTP relay hostname.";
      };

      relayPort = lib.mkOption {
        type = lib.types.port;
        description = "SMTP relay port.";
      };

      address = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SMTP account and sender address for realm services.";
      };
    };
  };
in
{
  options.host.mailer = lib.mkOption {
    type = with lib.types; nullOr mailerType;
    default = null;
    description = "SMTP delivery policy for services in this host's realm.";
  };
}
