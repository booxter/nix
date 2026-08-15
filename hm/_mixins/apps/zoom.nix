{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.host.hm.zoom.enable = lib.mkEnableOption "Zoom desktop client";

  config.home.packages = lib.optional config.host.hm.zoom.enable pkgs.zoom-us;
}
