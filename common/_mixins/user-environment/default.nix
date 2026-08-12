{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  emailCfg = cfg.features.apps.email;
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
      containers = {
        enable = lib.mkEnableOption "Podman container development environment";

        machine.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to manage a Podman virtual machine on Darwin.";
        };

        desktop.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to provide Podman Desktop.";
        };
      };

      shell = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the command-line power-user environment.";
        };

        llm = {
          enable = lib.mkEnableOption "local LLM tooling";

          ramalama.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to provide RamaLama.";
          };
        };
      };

      net = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide network diagnostic tools.";
        };

        graphical.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to provide graphical network diagnostic tools.";
        };
      };

      dev = {
        enable = lib.mkEnableOption "development tool suite";

        cli.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide command-line development tools.";
        };

        nix.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide Nix development tools.";
        };

        editor.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the development editor environment.";
        };

        attentionInbox.enable = lib.mkEnableOption "attention inbox";

        agents = {
          codex = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to provide the Codex coding agent.";
            };

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

          opencode.enable = lib.mkEnableOption "OpenCode coding agent";
        };

        scm = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to provide the source-control development environment.";
          };

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

        nvidia.enable = lib.mkEnableOption "NVIDIA development environment";
      };

      gui = {
        enable = lib.mkEnableOption "managed graphical desktop environment";
        x11.enable = lib.mkEnableOption "X11 desktop integration";
      };

      apps = {
        enable = lib.mkEnableOption "graphical workstation application suite";

        communication.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide graphical communication clients.";
        };

        notes.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the graphical notes application.";
        };

        music.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the managed Spotify client.";
        };

        chatgpt.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the ChatGPT desktop client where supported.";
        };

        email = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to provide the managed email environment.";
          };

          account = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "gmail";
            description = "Named email account configured on this host.";
          };

        };

        firefox = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to provide the managed Firefox browser.";
          };

          makeDefault = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to make Firefox the default browser where supported.";
          };
        };

        homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";
        teams.enable = lib.mkEnableOption "Microsoft Teams desktop workflow";
      };

      security.pass.enable = lib.mkEnableOption "password-store environment";

      ssh.enable = lib.mkEnableOption "SSH client environment";
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
          pass = lib.optional cfg.features.security.pass.enable "pass";
        };
      };

      features = lib.mkMerge [
        (lib.mkIf cfg.roles.developer.enable {
          dev.enable = lib.mkDefault true;
          security.pass.enable = lib.mkDefault true;
          ssh.enable = lib.mkDefault true;
        })
        (lib.mkIf cfg.roles.workstation.enable {
          apps.enable = lib.mkDefault true;
          gui.enable = lib.mkDefault true;
          net.graphical.enable = lib.mkDefault true;
        })
        (lib.mkIf (cfg.roles.workstation.enable && config.host.isDarwin) {
          apps.homerow.enable = lib.mkDefault true;
        })
      ];
    };

    assertions = [
      {
        assertion = !cfg.features.apps.enable || config.host.isDesktop;
        message = "The graphical workstation application suite requires a desktop host.";
      }
      {
        assertion = !cfg.features.gui.enable || config.host.isDesktop;
        message = "The managed graphical desktop environment requires a desktop host.";
      }
      {
        assertion = !cfg.features.gui.x11.enable || cfg.features.gui.enable;
        message = "X11 desktop integration requires the graphical desktop environment.";
      }
      {
        assertion = !cfg.features.net.graphical.enable || cfg.features.net.enable;
        message = "Graphical network diagnostic tools require network diagnostics.";
      }
      {
        assertion = !cfg.features.net.graphical.enable || config.host.isDesktop;
        message = "Graphical network diagnostic tools require a desktop host.";
      }
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
        assertion = !cfg.features.apps.enable || !emailCfg.enable || emailAccount != null;
        message = "host.userEnvironment.features.apps.email.account must name a declared email account";
      }
      {
        assertion =
          !cfg.features.apps.enable
          || !emailCfg.enable
          || emailAccount == null
          || builtins.hasAttr emailAccount.identity cfg.identities;
        message = "selected email account must name a declared identity";
      }
      {
        assertion =
          !cfg.features.apps.enable
          || !emailCfg.enable
          || emailAccount == null
          || builtins.hasAttr emailAccount.smtpTransport cfg.smtpTransports;
        message = "selected email account must name a declared SMTP transport";
      }
      {
        assertion =
          !cfg.features.dev.enable
          || !cfg.features.dev.scm.enable
          || builtins.hasAttr cfg.features.dev.scm.identity cfg.identities;
        message = "host.userEnvironment.features.dev.scm.identity must name a declared identity";
      }
      {
        assertion =
          !cfg.features.dev.enable
          || !cfg.features.dev.scm.enable
          || !cfg.features.dev.scm.sendEmail.enable
          || builtins.hasAttr cfg.features.dev.scm.sendEmail.transport cfg.smtpTransports;
        message = "host.userEnvironment.features.dev.scm.sendEmail.transport must name a declared SMTP transport";
      }
    ];
  };
}
