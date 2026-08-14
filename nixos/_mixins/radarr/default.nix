{ lib, pkgs, ... }:
{
  imports = [
    (import ../servarr { name = "radarr"; })
    ./letterboxd-list.nix
  ];

  options.host.radarr.letterboxdList = {
    enable = lib.mkEnableOption "Letterboxd list bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./pkgs/letterboxd-list-radarr { };
      internal = true;
    };
  };
}
