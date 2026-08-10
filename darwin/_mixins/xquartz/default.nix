{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.xquartz;
  xquartz = pkgs.xquartz;
in
{
  options.host.xquartz = {
    enable = lib.mkEnableOption "XQuartz launchd integration";
  };

  config = lib.mkIf cfg.enable {
    # XQuartz itself is installed by Home Manager. The launchd jobs still need
    # package-internal helpers under libexec and etc/X11, which Home Manager's
    # profile symlink farm does not expose, so point launchd at the store path.
    launchd.user.agents.xquartz-startx = {
      command = lib.escapeShellArgs [
        "${xquartz}/libexec/launchd_startx"
        "${xquartz}/bin/startx"
        "--"
        "${xquartz}/bin/Xquartz"
      ];
      serviceConfig = {
        Label = "org.nixos.xquartz.startx";
        # XQuartz expects launchd to allocate DISPLAY as this socket name; X11.bin
        # derives the org.nixos.xquartz prefix from the bundle identifier.
        Sockets."org.nixos.xquartz:0".SecureSocketWithKey = "DISPLAY";
        ServiceIPC = true;
        EnableTransactions = true;
      };
    };

    launchd.daemons.xquartz-privileged-startx = {
      command = lib.escapeShellArgs [
        "${xquartz}/libexec/privileged_startx"
        "-d"
        "${xquartz}/etc/X11/xinit/privileged_startx.d"
      ];
      serviceConfig = {
        Label = "org.nixos.xquartz.privileged_startx";
        MachServices."org.nixos.xquartz.privileged_startx" = true;
        TimeOut = 120;
        EnableTransactions = true;
      };
    };
  };
}
