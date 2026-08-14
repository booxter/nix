{ config, lib, ... }:
let
  cfg = config.host.hm.env.repositories;
  requiredRepositories = lib.unique (lib.concatLists (builtins.attrValues cfg.requests));
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
  options.host.hm.env.repositories = {
    catalog = lib.mkOption {
      type = lib.types.attrsOf repositoryType;
      default = { };
      description = "Repositories available to environment consumers.";
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
      description = "Unique repositories required by environment consumers.";
    };
  };

  config = {
    host.hm.env.repositories = {
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
        gmailctl = lib.optional config.host.hm.gmailctl.enable "gmailctl";
        pass = lib.optional config.host.hm.pass.enable "pass";
      };
    };

    assertions = [
      {
        assertion = lib.all (name: builtins.hasAttr name cfg.catalog) requiredRepositories;
        message = "host.hm.env.repositories.requests must name declared repositories";
      }
      {
        assertion = lib.all (
          repository:
          !lib.hasPrefix "/" repository.destination.path
          && lib.all (component: component != "..") (lib.splitString "/" repository.destination.path)
        ) (builtins.attrValues cfg.catalog);
        message = "environment repository destinations must be safe relative paths";
      }
    ];
  };
}
