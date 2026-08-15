{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.host.hm.telegram.enable = lib.mkEnableOption "Telegram desktop client";

  config = lib.mkIf config.host.hm.telegram.enable {
    home.packages = [ pkgs.telegram-desktop ];
    host.hm.aerospace.workspaces.c.appBundleIds = [ "com.tdesktop.Telegram" ];
  };
}
