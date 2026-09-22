{ lib, pkgs, ... }:
let
  lidarrOptions = import ./options.nix { inherit lib pkgs; };
in
{
  imports = [
    (import ../servarr {
      name = "lidarr";
      extraOptions = lidarrOptions;
    })
    ./controller.nix
  ];
}
