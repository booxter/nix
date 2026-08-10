{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  emailCfg = cfg.features.email;
  emailAccount = cfg.emailAccounts.${emailCfg.account} or null;
  requiredRepositories = lib.unique (lib.concatLists (builtins.attrValues cfg.repositories.requests));
  authenticationType = lib.types.enum [
    "oauth2"
    "password"
  ];
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
  emailAccountType = lib.types.submodule {
    options = {
      identity = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Named identity used by the email account.";
      };

      flavor = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Home Manager email-provider flavor.";
      };

      imapAuthentication = lib.mkOption {
        type = authenticationType;
        default = "oauth2";
        description = "Authentication method used for incoming email.";
      };

      smtpTransport = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Named SMTP transport used by the email account.";
      };

      smtpAuthentication = lib.mkOption {
        type = authenticationType;
        default = "oauth2";
        description = "Authentication method used for outgoing email.";
      };
    };
  };
  repositoryType = lib.types.submodule {
    options = {
      remote = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Git remote used to synchronize the repository.";
      };

      destination = {
        base = lib.mkOption {
          type = lib.types.enum [
            "home"
            "xdgData"
          ];
          description = "Base directory used to resolve the repository checkout.";
        };

        path = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Repository checkout path relative to its base directory.";
        };
      };
    };
  };
in
{
  imports = [ ./presets.nix ];

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

    emailAccounts = lib.mkOption {
      type = lib.types.attrsOf emailAccountType;
      default = { };
      description = "Named email accounts available to user-environment features.";
    };

    repositories = {
      catalog = lib.mkOption {
        type = lib.types.attrsOf repositoryType;
        default = { };
        description = "Repositories available to user-environment consumers.";
      };

      requests = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.nonEmptyStr);
        default = { };
        description = "Repository requirements grouped by their declaring consumer.";
      };

      required = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = requiredRepositories;
        readOnly = true;
        internal = true;
        description = "Unique repositories required by user-environment consumers.";
      };
    };

    roles.developer.enable = lib.mkEnableOption "interactive software development environment";
    roles.workstation.enable = lib.mkEnableOption "graphical workstation user environment";

    features = {
      attentionInbox.enable = lib.mkEnableOption "attention inbox";

      cli = {
        enable = lib.mkEnableOption "interactive command-line development environment";

        passwordStore.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the pass password manager.";
        };

        ramalama.enable = lib.mkEnableOption "RamaLama local AI tooling";
      };

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

      email = {
        enable = lib.mkEnableOption "managed email environment";

        account = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "gmail";
          description = "Named email account configured on this host.";
        };

        thunderbird.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to configure the selected account in Thunderbird.";
        };

        gmailctl.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide gmailctl and keep its OAuth token active.";
        };
      };

      firefox = {
        enable = lib.mkEnableOption "managed Firefox browser";

        makeDefault = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to make Firefox the default browser where supported.";
        };
      };

      homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";

      microsoftTeams.enable = lib.mkEnableOption "Microsoft Teams desktop workflow";

      nvidiaDevelopment.enable = lib.mkEnableOption "NVIDIA development environment";

      podmanDesktop.enable = lib.mkEnableOption "Podman Desktop application";

      podmanMachine.enable = lib.mkEnableOption "managed Podman virtual machine";

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

      emailAccounts = {
        gmail = {
          identity = "personal";
          flavor = "gmail.com";
          smtpTransport = "gmail";
        };
        nvidia = {
          identity = "nvidia";
          flavor = "outlook.office365.com";
          smtpTransport = "nvidia";
          smtpAuthentication = "password";
        };
      };

      repositories = {
        catalog = {
          dotfiles = {
            remote = "git@github.com:booxter/dotfiles.git";
            destination = {
              base = "home";
              path = ".priv-bin";
            };
          };
          gmailctl = {
            remote = "git@github.com:booxter/gmailctl-private-config.git";
            destination = {
              base = "home";
              path = ".gmailctl";
            };
          };
          pass = {
            remote = "git@github.com:booxter/pass.git";
            destination = {
              base = "xdgData";
              path = "password-store";
            };
          };
        };

        requests = {
          gmailctl = lib.optionals (emailCfg.enable && emailCfg.gmailctl.enable) [ "gmailctl" ];
          passwordStore = lib.optionals (cfg.features.cli.enable && cfg.features.cli.passwordStore.enable) [
            "pass"
          ];
        };
      };

      features = lib.mkMerge [
        (lib.mkIf cfg.roles.developer.enable {
          cli.enable = lib.mkDefault true;
          codex.enable = lib.mkDefault true;
          scm.enable = lib.mkDefault true;
        })
        (lib.mkIf cfg.roles.workstation.enable {
          email.enable = lib.mkDefault true;
          firefox.enable = lib.mkDefault true;
        })
        (lib.mkIf (cfg.roles.workstation.enable && config.host.isDarwin) {
          homerow.enable = lib.mkDefault true;
        })
        (lib.mkIf (cfg.roles.developer.enable && config.host.isDarwin) {
          podmanMachine.enable = lib.mkDefault true;
        })
      ];
    };

    assertions = [
      {
        assertion = lib.all (name: builtins.hasAttr name cfg.repositories.catalog) requiredRepositories;
        message = "host.userEnvironment.repositories.requests must name declared repositories";
      }
      {
        assertion = lib.all (
          repository:
          !lib.hasPrefix "/" repository.destination.path
          && lib.all (component: component != "..") (lib.splitString "/" repository.destination.path)
        ) (builtins.attrValues cfg.repositories.catalog);
        message = "host.userEnvironment repository destinations must be safe relative paths";
      }
      {
        assertion = !emailCfg.enable || emailAccount != null;
        message = "host.userEnvironment.features.email.account must name a declared email account";
      }
      {
        assertion =
          !emailCfg.enable || emailAccount == null || builtins.hasAttr emailAccount.identity cfg.identities;
        message = "selected email account must name a declared identity";
      }
      {
        assertion =
          !emailCfg.enable
          || emailAccount == null
          || builtins.hasAttr emailAccount.smtpTransport cfg.smtpTransports;
        message = "selected email account must name a declared SMTP transport";
      }
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
