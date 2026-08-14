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
  imports = [
    ./nvidia.nix
    ./personal.nix
  ];

  options.host.userEnvironment = {
    preset = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "nvidia"
          "personal"
        ]
      );
      default = null;
      description = "Named fleet policy providing overridable user-environment defaults.";
    };

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

    sendEmail.transport = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "gmail";
      description = "Named SMTP transport used by Git send-email.";
    };

    homerow.enable = lib.mkEnableOption "Homerow keyboard navigation";
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
          pass = lib.optional config.home-manager.users.${config.host.username}.host.hm.pass.enable "pass";
        };
      };

      homerow.enable = lib.mkDefault (
        cfg.roles.workstation.enable && config.nixpkgs.hostPlatform.isDarwin
      );
    };

    home-manager.users.${config.host.username}.host.hm.pass.enable =
      lib.mkDefault cfg.roles.developer.enable;

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
        assertion =
          !cfg.roles.developer.enable || builtins.hasAttr cfg.sendEmail.transport cfg.smtpTransports;
        message = "host.userEnvironment.sendEmail.transport must name a declared SMTP transport";
      }
    ];
  };
}
