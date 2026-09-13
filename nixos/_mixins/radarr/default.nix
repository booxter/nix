{ lib, pkgs, ... }:
let
  radarrOptions = import ./options.nix { inherit lib pkgs; };
in
{
  imports = [
    (import ../servarr {
      name = "radarr";
      extraOptions = radarrOptions;
    })
    ./controller.nix
    ./letterboxd-list.nix
    ./repair.nix
    ./worker.nix
  ];
}
