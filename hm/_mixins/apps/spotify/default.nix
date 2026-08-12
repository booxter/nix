{ lib, ... }:
{
  imports = [ ./spicetify.nix ];

  options.host.hm.spotify.enable = lib.mkEnableOption "managed Spotify client";
}
