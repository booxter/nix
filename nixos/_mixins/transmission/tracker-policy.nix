{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg;
  packages = import ./pkgs pkgs;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  metricsFile = "${nodeExporterTextfileDir}/transmission-collector.prom";
  serviceDeps = [
    "network-online.target"
    "nginx.service"
    "transmission.service"
  ];
  commonExecStart = [
    "--rpc-url"
    model.rpcUrl
    "--trackers-file"
    config.sops.secrets.transmissionTrackerHosts.path
    "--non-preferred-low-priority-ratio"
    (toString cfg.trackerPolicy.nonPreferred.lowPriorityRatio)
    "--non-preferred-pause-ratio"
    (toString cfg.trackerPolicy.nonPreferred.pauseRatio)
    "--interval-seconds"
    (toString cfg.trackerPolicy.intervalSeconds)
    "--request-timeout-seconds"
    (toString cfg.trackerPolicy.requestTimeoutSeconds)
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
        User = cfg.user;
        Group = cfg.group;
      };
    };
in
{
  config = lib.mkIf (cfg.enable && cfg.trackerPolicy.enable) {
    sops.secrets.transmissionTrackerHosts = {
      key = cfg.trackerPolicy.secret.key;
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "z ${nodeExporterTextfileDir} 0775 root ${cfg.group} - -"
    ];

    systemd.services = {
      transmission-prioritizer = mkTrackerService {
        description = "Enforce Transmission torrent priorities for selected private trackers";
        package = packages.prioritizer;
      };
      transmission-collector = mkTrackerService {
        description = "Collect Transmission torrent metrics";
        package = packages.collector;
        extraArgs = [
          "--metrics-file"
          metricsFile
        ];
      };
    };
  };
}
