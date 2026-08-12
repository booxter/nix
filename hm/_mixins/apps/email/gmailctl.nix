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
{
  options.host.hm.gmailctl = {
    enable = lib.mkEnableOption "gmailctl";
    warmer.enable = lib.mkEnableOption "periodic gmailctl OAuth token warmer";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.warmer.enable || cfg.enable;
          message = "host.hm.gmailctl.warmer requires host.hm.gmailctl";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      home.packages = [
        pkgs.gmailctl
      ];

      launchd.agents.gmailctl-warmer = lib.mkIf (isDarwin && cfg.warmer.enable) {
        enable = true;
        config = {
          ProgramArguments = gmailctlWarmerCommand;
          ProcessType = "Background";
          StartCalendarInterval = {
            Weekday = 1;
            Hour = 10;
            Minute = 0;
          };
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/gmailctl-warmer.log";
        };
      };

      systemd.user.services.gmailctl-warmer = lib.mkIf (!isDarwin && cfg.warmer.enable) {
        Unit.Description = "Warm the gmailctl OAuth refresh token";

        Service = {
          Type = "oneshot";
          ExecStart = lib.escapeShellArgs gmailctlWarmerCommand;
        };
      };

      systemd.user.timers.gmailctl-warmer = lib.mkIf (!isDarwin && cfg.warmer.enable) {
        Unit.Description = "Warm the gmailctl OAuth refresh token";

        Timer = {
          OnCalendar = "weekly";
          Persistent = true;
        };

        Install.WantedBy = [ "timers.target" ];
      };
    })
  ];
}
