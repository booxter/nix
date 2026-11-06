{
  config,
  lib,
  transmissionModel,
  pkgs,
  transmissionPolicyFile,
  utils,
  ...
}:
let
  model = transmissionModel;
  inherit (model) cfg;
  package = (import ./pkgs pkgs).torrentCleaner;
  policy = model.torrentPolicy;
  command = utils.escapeSystemdExecArgs (
    [
      (lib.getExe package)
      "--rpc-url"
      model.rpcUrl
      "--trackers-file"
      config.sops.templates."transmission-tracker-aliases.json".path
      "--policy-file"
      transmissionPolicyFile
      "--history-file"
      "/var/lib/transmission-torrent-cleaner/uploads.json"
      "--request-timeout-seconds"
      (toString policy.requestTimeoutSeconds)
    ]
    ++ lib.optional policy.deleteOnCleanup "--delete"
  );
in
{
  config = lib.mkIf (cfg != null && cfg.torrentPolicy != null) {
    systemd.services.transmission-torrent-cleaner = {
      description = "Cleanup for old Transmission torrents with tracker retention floors";
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
        StateDirectory = "transmission-torrent-cleaner";
        StateDirectoryMode = "0700";
        UMask = "0077";
      };
    };

    systemd.timers.transmission-torrent-cleaner = {
      description = "Periodic Transmission retention policy scan";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = policy.cleanupSchedule;
        OnUnitActiveSec = policy.cleanupSchedule;
        Persistent = true;
        Unit = "transmission-torrent-cleaner.service";
      };
    };
  };
}
