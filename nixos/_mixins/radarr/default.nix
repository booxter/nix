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
    ./letterboxd-list.nix
    ./repair.nix
  ];
}
