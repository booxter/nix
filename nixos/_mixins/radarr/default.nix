{ lib, pkgs, ... }:
let
  radarrOptions = import ./options.nix { inherit lib pkgs; };
in
{
  imports = [
    (import ../servarr {
      name = "radarr";
      apiKeySecret = "radarr/apiKey";
      extraOptions = radarrOptions;
    })
    ./letterboxd-list.nix
    ./repair.nix
  ];
}
