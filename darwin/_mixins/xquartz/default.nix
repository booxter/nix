{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.host.xquartz;
in
{
  options.host.xquartz = {
    enable = lib.mkEnableOption "XQuartz desktop integration";

    package = lib.mkPackageOption pkgs "xquartz" { };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    launchd.agents.xquartz-startx.serviceConfig = {
      Label = "org.nixos.xquartz.startx";
      ProgramArguments = [
        "${cfg.package}/libexec/launchd_startx"
        "${cfg.package}/bin/startx"
        "--"
        "${cfg.package}/bin/Xquartz"
      ];
      Sockets."org.nixos.xquartz:0".SecureSocketWithKey = "DISPLAY";
      ServiceIPC = true;
      EnableTransactions = true;
    };

    launchd.daemons.xquartz-privileged-startx.serviceConfig = {
      Label = "org.nixos.xquartz.privileged_startx";
      ProgramArguments = [
        "${cfg.package}/libexec/privileged_startx"
        "-d"
        "${cfg.package}/etc/X11/xinit/privileged_startx.d"
      ];
      MachServices."org.nixos.xquartz.privileged_startx" = true;
      TimeOut = 120;
      EnableTransactions = true;
    };

    home-manager.users.${username}.programs.xquartz = {
      enable = true;
    };
  };
}
