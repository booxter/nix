{
  config,
  lib,
  pkgs,
  transmissionPublicSeedingLowRatio,
  ...
}:
{
  systemd.services.transmission-torrent-cleaner = {
    description = "Cleanup for old high-ratio public Transmission torrents";
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
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.transmission-torrent-cleaner)
        "--rpc-url"
        "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}/transmission/rpc"
        "--trackers-file"
        config.sops.secrets.transmissionTrackerHosts.path
        "--minimum-age-days"
        "30"
        "--minimum-ratio"
        transmissionPublicSeedingLowRatio
        "--request-timeout-seconds"
        "20"
        "--delete"
      ];
      User = "transmission";
      Group = "media";
    };
  };

  systemd.timers.transmission-torrent-cleaner = {
    description = "Periodic cleanup scan for old public Transmission torrents";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15m";
      OnUnitActiveSec = "6h";
      Persistent = true;
      Unit = "transmission-torrent-cleaner.service";
    };
  };
}
