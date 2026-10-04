{
  backupTopology,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  clientModel =
    if config.host.backups ? sources then
      import ./client/model.nix { inherit backupTopology config lib; }
    else
      null;
  clientJob = if clientModel == null then null else clientModel.job;
  localJobs = lib.optionalAttrs (clientJob != null) (
    {
      "restic-${clientJob.name}" = {
        service = "restic-backups-${clientJob.name}";
        title = clientJob.title;
        phase = "local";
      };
    }
    // builtins.mapAttrs (_: preparation: {
      inherit (preparation) service title;
      phase = "prep";
    }) clientJob.preparations
  );
  cloudRepositories =
    if !(config.host.backups ? server) || config.host.backups.server == null then
      { }
    else
      lib.filterAttrs (_: repository: repository.cloud.enable) backupTopology.server.repositories;
  cloudJobs = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "restic-${name}-cloud-offload" {
      service = "restic-${name}-cloud-offload";
      title = "${name} Cloud Offload";
      phase = "cloud";
    }
  ) cloudRepositories;
  jobs = localJobs // cloudJobs;

  textfileDir = "/var/lib/prometheus-node-exporter-textfile/backups";
  stateDir = "/var/lib/host-observability-backup-metrics";
  package = pkgs.callPackage ./pkgs/backup-metrics {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  jobsConfig = (pkgs.formats.json { }).generate "backup-metrics-jobs.json" {
    jobs = lib.mapAttrsToList (backupJob: job: {
      backup_job = backupJob;
      backup_title = job.title;
      phase = job.phase;
      unit = "${job.service}.service";
    }) jobs;
  };
  configureCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' package "backup-metrics-configure")
    "--config"
    jobsConfig
    "--state-directory"
    stateDir
    "--metrics-file"
    "${textfileDir}/backups.prom"
  ];
in
{
  config = lib.mkIf (jobs != { }) {
    # Removing the last job unregisters the whole directory, including results
    # written by a recorder that was already running during the switch.
    host.observability.nodeExporter.textfile.directories.backups = textfileDir;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root - -"
      "d ${textfileDir} 0755 root root - -"
    ];

    systemd.services = {
      backup-metrics-configured = {
        description = "Export configured backup jobs for node exporter";
        wantedBy = [ "multi-user.target" ];
        before = [ "prometheus-node-exporter.service" ];
        restartTriggers = [ jobsConfig ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = configureCommand;
        };
      };
    }
    // lib.mapAttrs' (
      backupJob: job:
      let
        recordCommand = utils.escapeSystemdExecArgs [
          (lib.getExe' package "backup-metrics-record")
          "--backup-job"
          backupJob
          "--state-directory"
          stateDir
          "--metrics-file"
          "${textfileDir}/backups.prom"
        ];
      in
      lib.nameValuePair job.service {
        wants = [ "backup-metrics-configured.service" ];
        after = [ "backup-metrics-configured.service" ];
        serviceConfig.ExecStopPost = lib.mkAfter [ "+${recordCommand}" ];
      }
    ) jobs;
  };
}
