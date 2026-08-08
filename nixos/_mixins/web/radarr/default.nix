{
  config,
  hostInventory,
  lib,
  ...
}:
let
  mkServarr = import ../servarr.nix {
    inherit config hostInventory lib;
  };
  servarrModule = mkServarr {
    name = "radarr";
    apiGroup = "radarr-api";
    forceMediaUMask = true;
  };
in
{
  imports = [ ./letterboxd-list.nix ];

  inherit (servarrModule) options config;
}
