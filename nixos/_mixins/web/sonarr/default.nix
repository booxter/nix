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
in
mkServarr {
  name = "sonarr";
  apiGroup = "sonarr-api";
  forceMediaUMask = true;
}
