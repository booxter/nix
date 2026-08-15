{ config, lib, ... }:
{
  options.host.hm.teams.enable = lib.mkEnableOption "Microsoft Teams desktop workflow";

  config = lib.mkIf config.host.hm.teams.enable {
    host.hm.aerospace.workspaces.t = {
      appBundleIds = [ "com.microsoft.teams2" ];
      monitor = "secondary";
    };
  };
}
