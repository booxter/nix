{
  config,
  lib,
  pkgs,
  transmissionNonPreferredLowPriorityRatio,
  ...
}:
let
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/transmission-tracker-prioritizer.prom";
in
{
  systemd.tmpfiles.rules = [
    "z ${nodeExporterTextfileDir} 0775 root media - -"
  ];

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
      ExecStart = lib.concatStringsSep " " ([
        (lib.getExe pkgs.transmission-tracker-prioritizer)
        "--rpc-url"
        "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}/transmission/rpc"
        "--trackers-file"
        config.sops.secrets.transmissionTrackerHosts.path
        "--metrics-file"
        metricsFile
        "--non-preferred-low-priority-ratio"
        (toString transmissionNonPreferredLowPriorityRatio)
        "--interval-seconds"
        "30"
        "--request-timeout-seconds"
        "20"
      ]);
      Restart = "always";
      RestartSec = "10s";
      # The daemon rereads the tracker file every iteration, so secret updates
      # are picked up without an activation-time systemd restart hook.
      User = "transmission";
      Group = "media";
    };
  };
}
