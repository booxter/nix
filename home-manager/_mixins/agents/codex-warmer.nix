{
  config,
  lib,
  pkgs,
  isWork,
  ...
}:
let
  codexWarmer = (import ./pkgs { inherit pkgs; }).codex-warmer;
  codexWarmerEnabled = !isWork;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
in
{
  home.packages = lib.optionals codexWarmerEnabled [ codexWarmer ];

  launchd.agents.codex-warmer = lib.mkIf (isDarwin && codexWarmerEnabled) {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe codexWarmer) ];
      ProcessType = "Background";
      RunAtLoad = true;
      StartInterval = 300;
      ThrottleInterval = 60;
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/codex-warmer.log";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/codex-warmer.log";
    };
  };

  systemd.user.services.codex-warmer = lib.mkIf (!isDarwin && codexWarmerEnabled) {
    Unit.Description = "Keep the Codex five-hour usage window active";

    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe codexWarmer;
    };
  };

  systemd.user.timers.codex-warmer = lib.mkIf (!isDarwin && codexWarmerEnabled) {
    Unit.Description = "Periodically check the Codex five-hour usage window";

    Timer = {
      OnBootSec = "1m";
      OnUnitActiveSec = "5m";
    };

    Install.WantedBy = [ "timers.target" ];
  };
}
