{
  lib,
  pkgs,
  ...
}:
let
  serverType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        host = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = name;
        };
        displayName = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = name;
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 563;
        };
        timeout = lib.mkOption {
          type = lib.types.ints.positive;
          default = 90;
        };
        connections = lib.mkOption {
          type = lib.types.ints.positive;
        };
        tls = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
          verify = lib.mkOption {
            type = lib.types.ints.between 0 3;
            default = 3;
          };
        };
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        required = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        priority = lib.mkOption {
          type = lib.types.int;
        };
        credentialsSecretPrefix = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "sabnzbd/servers/${name}";
        };
      };
    }
  );
in
{
  options.host.sabnzbd = {
    enable = lib.mkEnableOption "SABnzbd usenet downloader";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sabnzbd;
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6336;
    };

    storage = {
      claim = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "media";
      };
      relativePath = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "usenet";
      };
    };

    vpn.namespace = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "wg";
    };

    servers = lib.mkOption {
      type = lib.types.attrsOf serverType;
      default = { };
      description = "Usenet servers configured in SABnzbd.";
    };

    secrets = {
      apiKey = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "sabnzbd/apiKey";
      };
      nzbKey = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "sabnzbd/nzbKey";
      };
    };

    metrics.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };

    completeDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      readOnly = true;
      internal = true;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "sabnzbd";
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
      internal = true;
    };
  };
}
