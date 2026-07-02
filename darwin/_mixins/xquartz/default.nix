{
  config,
  lib,
  username,
  ...
}:
let
  cfg = config.host.xquartz;
in
{
  options.host.xquartz.enable = lib.mkEnableOption "XQuartz desktop integration";

  config = lib.mkIf cfg.enable {
    home-manager.users.${username}.programs.xquartz.enable = true;
  };
}
