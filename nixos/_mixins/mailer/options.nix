{ lib, ... }:
let
  mailerType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        smtp = {
          host = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "SMTP relay hostname.";
          };

          port = lib.mkOption {
            type = lib.types.port;
            description = "SMTP relay port.";
          };

          username = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "SMTP authentication username.";
          };
        };

        fromAddress = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Default sender address for realm services.";
        };

        replyToAddress = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = config.fromAddress;
          defaultText = lib.literalExpression "config.fromAddress";
          description = "Default reply-to address for realm services.";
        };
      };
    }
  );
in
{
  options.host.mailer = lib.mkOption {
    type = with lib.types; nullOr mailerType;
    default = null;
    description = "SMTP delivery policy for services in this host's realm.";
  };
}
