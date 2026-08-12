{ config, lib, ... }:
let
  cfg = config.host.hm.spotify;
in
{
  imports = [ ./spicetify.nix ];

  options.host.hm.spotify = {
    enable = lib.mkEnableOption "managed Spotify client";
    spicetify.enable = lib.mkEnableOption "Spicetify customization";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.spicetify.enable || cfg.enable;
          message = "host.hm.spotify.spicetify requires host.hm.spotify";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      host.hm.aerospace.workspaces.s.appBundleIds = [ "com.spotify.client" ];
    })
  ];
}
