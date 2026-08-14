{
  backupTopology,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit backupTopology config lib; };
  inherit (model)
    applicationKeyFile
    applicationKeyIdFile
    b2Offloads
    cfg
    dependencyUnits
    offloadService
    requiredUnits
    server
    ;
  enabled = b2Offloads != { };
  resticTools = pkgs.callPackage ./pkgs/restic-tools {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  usageConfig = (pkgs.formats.json { }).generate "restic-cloud-usage.json" {
    buckets = [ cfg.offsite.bucket ];
    b2ApplicationKeyIdFile = applicationKeyIdFile;
    b2ApplicationKeyFile = applicationKeyFile;
    repositories = lib.mapAttrsToList (name: repository: {
      inherit name;
      backupJob = offloadService name;
      backupTitle = "${name} Cloud Offload";
      bucket = cfg.offsite.bucket;
      inherit (repository.cloud) prefix repository;
      passwordFile = repository.cloud.passwordFile;
    }) b2Offloads;
  };
  command = utils.escapeSystemdExecArgs [
    (lib.getExe' resticTools "restic-cloud-usage")
    "--config"
    usageConfig
    "--state-file"
    "/var/lib/restic-cloud-usage-metrics/state.json"
    "--metrics-file"
    "/var/lib/prometheus-node-exporter-textfile/restic-cloud-usage.prom"
    "--restic-cache-dir"
    "/var/lib/restic-cloud-usage-metrics/restic-cache"
  ];
in
{
  config = lib.mkIf (server != null && enabled) {
    systemd.services.restic-cloud-usage-export = {
      description = "Export Restic cloud and B2 usage metrics";
      wants = dependencyUnits;
      after = dependencyUnits ++ requiredUnits;
      requires = requiredUnits;
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "restic-cloud-usage-metrics";
        TimeoutStartSec = "2h";
        ExecStart = command;
      };
    };

    systemd.timers.restic-cloud-usage-export = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 00/4:00:00";
        RandomizedDelaySec = "10m";
        Persistent = true;
      };
    };
  };
}
