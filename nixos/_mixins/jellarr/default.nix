{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  localHost = config.networking.hostName;
  model = import ./model.nix { inherit config outputs; };
in
{
  imports = [
    inputs.jellarr.nixosModules.default
    ./assertions.nix
    ./service.nix
  ];

  options.host.jellarr = {
    enable = lib.mkEnableOption "Jellarr declarative Jellyfin configuration";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package { src = inputs.jellarr; };
      description = "Jellarr package to run.";
    };

    target = {
      host = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = localHost;
        description = "NixOS host running the Jellyfin instance managed by Jellarr.";
      };

      url = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = model.url;
        readOnly = true;
        internal = true;
        description = "Jellyfin API URL reachable from the Jellarr host.";
      };
    };
  };
}
