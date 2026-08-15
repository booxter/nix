{
  config,
  lib,
  storageModel,
  ...
}:
let
  serverType = lib.types.submodule {
    options = {
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 90;
      };
      connections = lib.mkOption { type = lib.types.ints.positive; };
      tlsVerification = lib.mkOption {
        type = lib.types.enum [
          "strict"
          "allow injection"
          "none"
        ];
        default = "strict";
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      required = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      priority = lib.mkOption { type = lib.types.int; };
    };
  };
in
{
  imports = [
    ./account.nix
    ./assertions.nix
    ./downloads.nix
    ./metrics.nix
    ./secrets.nix
    ./service.nix
    ./storage.nix
    ./vpn.nix
    ./web.nix
  ];

  options.host.sabnzbd = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options.servers = lib.mkOption {
          type = lib.types.attrsOf serverType;
          default = { };
          description = "Usenet servers configured in SABnzbd.";
        };
      }
    );
    default = null;
    description = "SABnzbd usenet downloader configuration.";
  };

  config._module.args.sabnzbdModel = import ./model.nix { inherit config lib storageModel; };
}
