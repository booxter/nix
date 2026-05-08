{
  config,
  lib,
  pkgs,
  ...
}:
let
  stateDir = "/var/lib/transmission-tracker-prioritizer";
  managedTorrentsStateFile = "${stateDir}/managed-torrents.json";
in
{
  sops.secrets.transmissionTrackerHosts = {
    key = "transmission/private_tracker_hosts";
    owner = "transmission";
    group = "media";
    mode = "0400";
  };

  systemd.services.transmission-tracker-prioritizer = {
    description = "Prefer uploads for torrents on selected private trackers";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "nginx.service"
      "transmission.service"
    ];
    wants = [
      "network-online.target"
      "nginx.service"
      "transmission.service"
    ];
    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe pkgs.transmission-tracker-prioritizer)
        "--rpc-url"
        "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}/transmission/rpc"
        "--trackers-file"
        config.sops.secrets.transmissionTrackerHosts.path
        "--state-file"
        managedTorrentsStateFile
        "--interval-seconds"
        "60"
        "--request-timeout-seconds"
        "20"
      ];
      Restart = "always";
      RestartSec = "10s";
      StateDirectory = "transmission-tracker-prioritizer";
      StateDirectoryMode = "0750";
      # The daemon rereads the tracker file every iteration, so secret updates
      # are picked up without an activation-time systemd restart hook.
      User = "transmission";
      Group = "media";
    };
  };
}
