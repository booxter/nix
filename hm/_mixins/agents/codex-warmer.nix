{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  codexWarmerPackage = (import ./pkgs { inherit pkgs; }).codex-warmer;
  codexWarmer = lib.getExe' codexWarmerPackage "codex-warmer";
  codexWarmerEnabled = !isWork;
  inherit (osConfig.host) isDarwin isWork;
in
{
  home.packages = lib.optionals codexWarmerEnabled [ codexWarmerPackage ];

  launchd.agents.codex-warmer = lib.mkIf (isDarwin && codexWarmerEnabled) {
    enable = true;
    config = {
      ProgramArguments = [ codexWarmer ];
      ProcessType = "Background";
      RunAtLoad = true;
      StartInterval = 300;
      ThrottleInterval = 60;
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/codex-warmer.log";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/codex-warmer.log";
    };
  };

  systemd.user.services.codex-warmer = lib.mkIf (!isDarwin && codexWarmerEnabled) {
    Unit.Description = "Keep Codex usage windows active";

    Service = {
      Type = "oneshot";
      ExecStart = codexWarmer;
    };
  };

  systemd.user.timers.codex-warmer = lib.mkIf (!isDarwin && codexWarmerEnabled) {
    Unit.Description = "Periodically check Codex usage windows";

    Timer = {
      OnBootSec = "1m";
      OnUnitActiveSec = "5m";
    };

    Install.WantedBy = [ "timers.target" ];
  };
}
