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
    ./assertions.nix
    ./controller.nix
    ./letterboxd-list.nix
  ];
}
