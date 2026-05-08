{
  config,
  lib,
  pkgs,
  ...
}:
let
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/transmission-tracker-prioritizer.prom";
  # Keep the public-group reserve tied to Transmission's own upload ceiling so
  # changing the base uplink budget automatically retunes both limits together.
  publicGroupUploadLimitKBps = builtins.floor (
    config.nixarr.transmission.extraSettings."speed-limit-up" * 0.4
  );
in
{
  systemd.tmpfiles.rules = [
    "z ${nodeExporterTextfileDir} 0775 root media - -"
  ];

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
        "--public-group-name"
        "public-low-priority"
        "--public-group-upload-limit-kbps"
        (toString publicGroupUploadLimitKBps)
        "--bandwidth-state-file"
        "/run/adaptive-upload-policy/state.json"
        "--metrics-file"
        metricsFile
        "--interval-seconds"
        "60"
        "--request-timeout-seconds"
        "20"
      ];
      Restart = "always";
      RestartSec = "10s";
      # The daemon rereads the tracker file every iteration, so secret updates
      # are picked up without an activation-time systemd restart hook.
      User = "transmission";
      Group = "media";
    };
  };
}
