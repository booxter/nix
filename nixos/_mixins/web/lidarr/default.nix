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
    name = "lidarr";
    apiGroup = "lidarr-api";
    addUserToApiGroup = false;
  };
in
{
  imports = [ ./cue-splitter.nix ];

  inherit (servarrModule) options;

  config = lib.mkMerge [
    servarrModule.config
    (lib.mkIf config.host.lidarr.enable {
      services.lidarr.cueSplitter.enable = true;
    })
  ];
}
