{
  config,
  lib,
  pkgs,
  ...
}:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  cfg = config.host.hm.gmailctl;
  gmailctlConfigDir = "${config.home.homeDirectory}/.gmailctl";
  gmailctlExe = lib.getExe' pkgs.gmailctl "gmailctl";
  gmailctlWarmerCommand = [
    gmailctlExe
    "--color=never"
    "--config"
    gmailctlConfigDir
    "download"
    "--output"
    "/dev/null"
  ];
in
lib.mkIf (cfg.enable && cfg.warmer.enable) {
  launchd.agents.gmailctl-warmer = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = gmailctlWarmerCommand;
      ProcessType = "Background";
      StartCalendarInterval = {
        Weekday = 1;
        Hour = 10;
        Minute = 0;
      };
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/gmailctl-warmer.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/gmailctl-warmer.log";
    };
  };

  systemd.user.services.gmailctl-warmer = lib.mkIf (!isDarwin) {
    Unit.Description = "Warm the gmailctl OAuth refresh token";

    Service = {
      Type = "oneshot";
      ExecStart = lib.escapeShellArgs gmailctlWarmerCommand;
    };
  };

  systemd.user.timers.gmailctl-warmer = lib.mkIf (!isDarwin) {
    Unit.Description = "Warm the gmailctl OAuth refresh token";

    Timer = {
      OnCalendar = "weekly";
      Persistent = true;
    };

    Install.WantedBy = [ "timers.target" ];
  };
}
