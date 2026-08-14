{
  config,
  lib,
  storageModel,
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
        connections = lib.mkOption { type = lib.types.ints.positive; };
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
        priority = lib.mkOption { type = lib.types.int; };
        credentialsSecretPrefix = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "sabnzbd/servers/${name}";
        };
      };
    }
  );
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
