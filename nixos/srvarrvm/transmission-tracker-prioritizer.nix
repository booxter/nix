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
  serviceDeps = [
    "network-online.target"
    "nginx.service"
    "transmission.service"
  ];
  commonExecStart = [
    "--rpc-url"
    "http://127.0.0.1:${toString config.nixarr.transmission.uiPort}/transmission/rpc"
    "--trackers-file"
    config.sops.secrets.transmissionTrackerHosts.path
    "--non-preferred-low-priority-ratio"
    (toString transmissionNonPreferredLowPriorityRatio)
    "--interval-seconds"
    "30"
    "--request-timeout-seconds"
    "20"
  ];
  mkTrackerService =
    {
      description,
      package,
      extraArgs ? [ ],
    }:
    {
      inherit description;
      wantedBy = [ "multi-user.target" ];
      after = serviceDeps;
      wants = serviceDeps;
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " ([ (lib.getExe package) ] ++ commonExecStart ++ extraArgs);
        Restart = "always";
        RestartSec = "10s";
        # The daemon rereads the tracker file every iteration, so secret updates
        # are picked up without an activation-time systemd restart hook.
        User = "transmission";
        Group = "media";
      };
    };
in
{
  systemd.tmpfiles.rules = [
    "z ${nodeExporterTextfileDir} 0775 root media - -"
  ];

  systemd.services = {
    transmission-tracker-prioritizer = mkTrackerService {
      description = "Enforce Transmission torrent priorities for selected private trackers";
      package = pkgs.transmission-tracker-prioritizer;
    };

    transmission-tracker-prioritizer-collector = mkTrackerService {
      description = "Collect Transmission torrent priority metrics";
      package = pkgs.transmission-tracker-prioritizer-collector;
      extraArgs = [
        "--metrics-file"
        metricsFile
      ];
    };
  };
}
