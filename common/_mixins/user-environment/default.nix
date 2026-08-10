{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  identityType = lib.types.submodule {
    options = {
      fullName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Full name associated with the identity.";
      };

      email = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Email address associated with the identity.";
      };
    };
  };
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
    identities = lib.mkOption {
      type = lib.types.attrsOf identityType;
      default = { };
      description = "Named user identities available to user-environment features.";
    };

    smtpTransports = lib.mkOption {
      type = lib.types.attrsOf smtpTransportType;
      default = { };
      description = "Named SMTP transports available to user-environment features.";
    };

    roles.developer.enable = lib.mkEnableOption "interactive software development environment";

    features = {
      codex = {
        enable = lib.mkEnableOption "Codex coding agent";

        usageStatus.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide standard Codex usage status integration.";
        };

        resetCredits.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the Codex reset-credits utility.";
        };

        workUsageStatus.enable = lib.mkEnableOption "work Codex usage status integration";

        warmer.enable = lib.mkEnableOption "periodic Codex usage-window warmer";
      };

      scm = {
        enable = lib.mkEnableOption "source-control development environment";

        identity = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "personal";
          description = "Named identity used by source-control tools.";
        };

        sendEmail = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to configure Git send-email.";
          };

          transport = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "gmail";
            description = "Named SMTP transport used by Git send-email.";
          };
        };
      };
    };
  };

  config = {
    host.userEnvironment = {
      identities = {
        personal = {
          fullName = "Ihar Hrachyshka";
          email = "ihar.hrachyshka@gmail.com";
        };
        nvidia = {
          fullName = "Ihar Hrachyshka";
          email = "${config.host.username}@nvidia.com";
        };
      };

      smtpTransports = {
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

      features = lib.mkIf cfg.roles.developer.enable {
        codex.enable = lib.mkDefault true;
        scm.enable = lib.mkDefault true;
      };
    };

    assertions = [
      {
        assertion = !cfg.features.scm.enable || builtins.hasAttr cfg.features.scm.identity cfg.identities;
        message = "host.userEnvironment.features.scm.identity must name a declared identity";
      }
      {
        assertion =
          !cfg.features.scm.enable
          || !cfg.features.scm.sendEmail.enable
          || builtins.hasAttr cfg.features.scm.sendEmail.transport cfg.smtpTransports;
        message = "host.userEnvironment.features.scm.sendEmail.transport must name a declared SMTP transport";
      }
    ];
  };
}
