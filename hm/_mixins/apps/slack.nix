{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.host.hm.slack.enable = lib.mkEnableOption "Slack desktop client";

  config = lib.mkIf config.host.hm.slack.enable {
    home.packages = [ pkgs.slack ];
    host.hm.aerospace.workspaces.c.appBundleIds = [ "com.tinyspeck.slackmacgap" ];
  };
}
