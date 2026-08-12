{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.host.hm.matrix.enable = lib.mkEnableOption "Element Matrix client";

  config = lib.mkIf config.host.hm.matrix.enable {
    home.packages = [ pkgs.element-desktop ];
    host.hm.aerospace.workspaces.c.appBundleIds = [ "im.riot.app" ];
  };
}
