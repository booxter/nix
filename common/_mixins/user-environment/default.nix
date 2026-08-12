{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
  requiredRepositories = lib.unique (lib.concatLists (builtins.attrValues cfg.repositories.requests));
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
    smtpTransports = lib.mkOption {
      type = lib.types.attrsOf smtpTransportType;
      default = { };
      description = "Named SMTP transports available to user-environment features.";
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
      shell.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to provide the command-line power-user environment.";
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

        chatgpt.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to provide the ChatGPT desktop client where supported.";
        };

        firefox.makeDefault = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to make Firefox the default browser where supported.";
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
          gmailctl =
            lib.optional config.home-manager.users.${config.host.username}.host.hm.gmailctl.enable
              "gmailctl";
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
