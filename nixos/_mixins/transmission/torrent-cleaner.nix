{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg;
  package = (import ./pkgs pkgs).torrentCleaner;
in
{
  config = lib.mkIf (cfg.enable && cfg.torrentCleaner.enable) {
    systemd.services.transmission-torrent-cleaner = {
      description = "Cleanup for old public Transmission torrents";
      after = [
        "network-online.target"
        "nginx.service"
        "sops-install-secrets.service"
        "transmission.service"
      ];
      wants = [
        "network-online.target"
        "nginx.service"
        "sops-install-secrets.service"
        "transmission.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.concatStringsSep " " (
          [
            (lib.getExe package)
            "--rpc-url"
            model.rpcUrl
            "--trackers-file"
            config.sops.secrets.transmissionTrackerHosts.path
            "--minimum-age-days"
            (toString cfg.torrentCleaner.minimumAgeDays)
            "--minimum-ratio"
            (toString model.minimumCleanerRatio)
            "--maximum-age-days"
            (toString cfg.torrentCleaner.maximumAgeDays)
            "--request-timeout-seconds"
            (toString cfg.trackerPolicy.requestTimeoutSeconds)
          ]
          ++ lib.optional cfg.torrentCleaner.delete "--delete"
        );
        User = cfg.user;
        Group = cfg.group;
      };
    };

    systemd.timers.transmission-torrent-cleaner = {
      description = "Periodic cleanup scan for old public Transmission torrents";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.torrentCleaner.schedule;
        OnUnitActiveSec = cfg.torrentCleaner.schedule;
        Persistent = true;
        Unit = "transmission-torrent-cleaner.service";
      };
    };
  };
}
