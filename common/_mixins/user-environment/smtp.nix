{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  smtpTransportType = lib.types.submodule {
    options = {
      server = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SMTP server hostname.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 587;
        description = "SMTP server port.";
      };

      encryption = lib.mkOption {
        type = lib.types.enum [
          "none"
          "ssl"
          "tls"
        ];
        default = "tls";
        description = "SMTP transport encryption mode.";
      };

      username = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SMTP authentication username.";
      };

      credentialStore = lib.mkOption {
        type = lib.types.enum [
          "none"
          "macos-keychain"
        ];
        default = "none";
        description = "Credential store used by helpers for this transport.";
      };
    };
  };
in
{
  options.host.userEnvironment = {
    smtpTransports = lib.mkOption {
      type = lib.types.attrsOf smtpTransportType;
      default = { };
      description = "Named SMTP transports available to the user environment.";
    };

    sendEmail.transport = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "gmail";
      description = "Named SMTP transport used by Git send-email.";
    };
  };

  config = {
    host.userEnvironment.smtpTransports = {
      gmail = {
        server = "smtp.gmail.com";
        username = "ihar.hrachyshka@gmail.com";
        credentialStore = "macos-keychain";
      };
      nvidia = {
        server = "mail.nvidia.com";
        username = "${config.host.username}@nvidia.com";
      };
    };

    assertions = [
      {
        assertion =
          !cfg.roles.developer.enable || builtins.hasAttr cfg.sendEmail.transport cfg.smtpTransports;
        message = "host.userEnvironment.sendEmail.transport must name a declared SMTP transport";
      }
    ];
  };
}
