{
  config,
  isDarwin,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = osConfig.host.syncGitMains;
  syncGitMains = pkgs.callPackage ./pkgs/sync-git-mains {
    inherit (cfg) roots;
  };
in
{
  home.packages = lib.optionals cfg.enable [ syncGitMains ];

  launchd.agents.sync-git-mains = lib.mkIf (isDarwin && cfg.enable) {
    enable = true;
    config = {
      ProgramArguments = [ (lib.getExe syncGitMains) ];
      ProcessType = "Background";
      RunAtLoad = true;
      StartInterval = cfg.intervalSeconds;
      ThrottleInterval = 60;
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/sync-git-mains.log";
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/sync-git-mains.log";
    };
  };

  systemd.user.services.sync-git-mains = lib.mkIf (!isDarwin && cfg.enable) {
    Unit.Description = "Fast-forward local Git main branches from origin";

    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe syncGitMains;
    };
  };

  systemd.user.timers.sync-git-mains = lib.mkIf (!isDarwin && cfg.enable) {
    Unit.Description = "Periodically fast-forward local Git main branches from origin";

    Timer = {
      OnBootSec = "1m";
      OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
    };

    Install.WantedBy = [ "timers.target" ];
  };
}
