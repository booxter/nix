{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.transmission.cleaner;
  common = pkgs.callPackage ./packages/common { };
  package = pkgs.callPackage ./packages/cleaner {
    transmissionCommon = common;
  };
in
{
  options.services.transmission.cleaner = {
    enable = lib.mkEnableOption "old public Transmission torrent cleanup" // {
      default = true;
    };

    minimumAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Minimum torrent age eligible for ratio-based cleanup.";
    };

    minimumRatio = lib.mkOption {
      type = lib.types.number;
      default = config.services.transmission.prioritizer.nonPreferredLowPriorityRatio;
      description = "Minimum ratio eligible for cleanup after minimumAgeDays.";
    };

    maximumAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Torrent age that permits cleanup regardless of ratio.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "Interval between cleanup scans.";
    };
  };

  config = lib.mkIf (config.host.transmission.enable && cfg.enable) {
    assertions = [
      {
        assertion = cfg.minimumAgeDays <= cfg.maximumAgeDays;
        message = "Transmission cleaner minimumAgeDays must not exceed maximumAgeDays.";
      }
    ];

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
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe package)
          "--rpc-url"
          "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}/transmission/rpc"
          "--trackers-file"
          config.sops.secrets.transmissionTrackerHosts.path
          "--minimum-age-days"
          (toString cfg.minimumAgeDays)
          "--minimum-ratio"
          (toString cfg.minimumRatio)
          "--maximum-age-days"
          (toString cfg.maximumAgeDays)
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
        OnUnitActiveSec = cfg.interval;
        Persistent = true;
        Unit = "transmission-torrent-cleaner.service";
      };
    };
  };
}
