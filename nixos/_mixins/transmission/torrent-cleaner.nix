{
  config,
  lib,
  transmissionModel,
  pkgs,
  utils,
  ...
}:
let
  model = transmissionModel;
  inherit (model) cfg;
  package = (import ./pkgs pkgs).torrentCleaner;
  policy = model.torrentCleaner;
  command = utils.escapeSystemdExecArgs (
    [
      (lib.getExe package)
      "--rpc-url"
      model.rpcUrl
      "--trackers-file"
      config.sops.secrets.transmissionTrackerHosts.path
      "--minimum-age-days"
      (toString policy.minimumAgeDays)
      "--minimum-ratio"
      (toString policy.minimumRatio)
      "--maximum-age-days"
      (toString policy.maximumAgeDays)
      "--request-timeout-seconds"
      (toString model.trackerPolicy.requestTimeoutSeconds)
    ]
    ++ lib.optional policy.delete "--delete"
  );
in
{
  config = lib.mkIf (cfg != null && cfg.torrentCleaner != null) {
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
        ExecStart = command;
        User = model.user;
        Group = model.group;
      };
    };

    systemd.timers.transmission-torrent-cleaner = {
      description = "Periodic cleanup scan for old public Transmission torrents";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = policy.schedule;
        OnUnitActiveSec = policy.schedule;
        Persistent = true;
        Unit = "transmission-torrent-cleaner.service";
      };
    };
  };
}
