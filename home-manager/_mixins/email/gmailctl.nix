{
  config,
  lib,
  pkgs,
  isDarwin,
  ...
}:
let
  gmailctlConfigDir = "${config.home.homeDirectory}/.gmailctl";
  gmailctlExe = lib.getExe' pkgs.gmailctl "gmailctl";
  gmailctlKeepalive = pkgs.writeShellApplication {
    name = "gmailctl-token-keepalive";
    text = ''
      exec ${gmailctlExe} --color=never --config ${lib.escapeShellArg gmailctlConfigDir} download --output /dev/null
    '';
  };
in
{
  home.packages = [
    pkgs.gmailctl
  ];

  launchd.agents.gmailctl-token-keepalive = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe gmailctlKeepalive) ];
      ProcessType = "Background";
      StartCalendarInterval = {
        Weekday = 1;
        Hour = 10;
        Minute = 0;
      };
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/gmailctl-token-keepalive.log";
    };
  };

  systemd.user.services.gmailctl-token-keepalive = lib.mkIf (!isDarwin) {
    Unit.Description = "Keep gmailctl OAuth refresh token active";

    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe gmailctlKeepalive;
    };
  };

  systemd.user.timers.gmailctl-token-keepalive = lib.mkIf (!isDarwin) {
    Unit.Description = "Keep gmailctl OAuth refresh token active";

    Timer = {
      OnCalendar = "weekly";
      Persistent = true;
    };

    Install.WantedBy = [ "timers.target" ];
  };
}
