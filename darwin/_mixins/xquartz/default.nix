{
  config,
  lib,
  username,
  ...
}:
let
  cfg = config.host.xquartz;
  xquartzProfile = "/etc/profiles/per-user/${username}";
in
{
  options.host.xquartz = {
    enable = lib.mkEnableOption "XQuartz launchd integration";
  };

  config = lib.mkIf cfg.enable {
    launchd.user.agents.xquartz-startx.serviceConfig = {
      Label = "org.nixos.xquartz.startx";
      ProgramArguments = [
        "${xquartzProfile}/libexec/launchd_startx"
        "${xquartzProfile}/bin/startx"
        "--"
        "${xquartzProfile}/bin/Xquartz"
      ];
      Sockets."org.nixos.xquartz:0".SecureSocketWithKey = "DISPLAY";
      ServiceIPC = true;
      EnableTransactions = true;
    };

    launchd.daemons.xquartz-privileged-startx.serviceConfig = {
      Label = "org.nixos.xquartz.privileged_startx";
      ProgramArguments = [
        "${xquartzProfile}/libexec/privileged_startx"
        "-d"
        "${xquartzProfile}/etc/X11/xinit/privileged_startx.d"
      ];
      MachServices."org.nixos.xquartz.privileged_startx" = true;
      TimeOut = 120;
      EnableTransactions = true;
    };
  };
}
