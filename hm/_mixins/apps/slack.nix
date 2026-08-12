{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.host.hm.slack.enable = lib.mkEnableOption "Slack desktop client";

  config.home.packages = lib.optional config.host.hm.slack.enable pkgs.slack;
}
