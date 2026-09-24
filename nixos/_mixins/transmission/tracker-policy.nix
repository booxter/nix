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
  packages = import ./pkgs pkgs;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile/transmission-collector";
  metricsFile = "${nodeExporterTextfileDir}/transmission-collector.prom";
  serviceDeps = [
    "network-online.target"
    "nginx.service"
    "transmission.service"
  ];
  policy = model.torrentPolicy;
  commonArgs = [
    "--rpc-url"
    model.rpcUrl
    "--trackers-file"
    config.sops.secrets.transmissionTrackerHosts.path
    "--policy-file"
    transmissionPolicyFile
    "--interval-seconds"
    (toString policy.reconcileIntervalSeconds)
    "--request-timeout-seconds"
    (toString policy.requestTimeoutSeconds)
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
        ExecStart = utils.escapeSystemdExecArgs ([ (lib.getExe package) ] ++ commonArgs ++ extraArgs);
        Restart = "always";
        RestartSec = "10s";
        User = model.user;
        Group = model.group;
      };
    };
in
{
  config = lib.mkIf (cfg != null && cfg.torrentPolicy != null) {
    host.observability.nodeExporter.textfile.directories.transmission-collector =
      nodeExporterTextfileDir;

    sops.secrets.transmissionTrackerHosts = {
      key = "transmission/private_tracker_hosts";
      owner = model.user;
      group = model.group;
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d ${nodeExporterTextfileDir} 0755 ${model.user} ${model.group} - -"
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
