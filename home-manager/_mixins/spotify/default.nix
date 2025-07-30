{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.spotify-player.enable = true;
  home.packages = with pkgs; [
    spot
    spotify
  ];
}
