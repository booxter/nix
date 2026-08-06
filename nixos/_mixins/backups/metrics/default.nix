{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.observability.backupMetrics;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  stateDir = "/var/lib/host-observability-backup-metrics";
  sanitizeName =
    name:
    lib.replaceStrings
      [
        "/"
        "."
        " "
      ]
      [
        "-"
        "-"
        "-"
      ]
      name;
  package = pkgs.callPackage ./pkgs/backup-metrics {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  jobsConfig = (pkgs.formats.json { }).generate "backup-metrics-jobs.json" {
    jobs = lib.mapAttrsToList (backupJob: job: {
      backup_job = backupJob;
      backup_title = job.title;
      phase = job.phase;
      unit = "${job.service}.service";
    }) cfg.jobs;
  };
  configureCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' package "backup-metrics-configure")
    "--config"
    jobsConfig
    "--metrics-file"
    "${textfileDir}/backup-jobs-configured.prom"
  ];
in
{
  options.host.observability.backupMetrics.jobs = lib.mkOption {
    type =
      with lib.types;
      attrsOf (submodule {
        options = {
          service = lib.mkOption {
            type = str;
            description = "Systemd service name, without the .service suffix.";
          };

          title = lib.mkOption {
            type = str;
            description = "Human-oriented backup job title.";
          };

          phase = lib.mkOption {
            type = str;
            description = "Backup phase label such as prep, local, or cloud.";
          };
        };
      });
    default = { };
    description = "Backup-related systemd services whose last-run outcome should be exported through node_exporter textfiles.";
  };

  config = lib.mkIf (cfg.jobs != { }) {
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
        metricsBase = sanitizeName backupJob;
        unitName = "${job.service}.service";
        recordCommand = utils.escapeSystemdExecArgs [
          (lib.getExe' package "backup-metrics-record")
          "--backup-job"
          backupJob
          "--backup-title"
          job.title
          "--phase"
          job.phase
          "--unit"
          unitName
          "--state-file"
          "${stateDir}/${metricsBase}.json"
          "--metrics-file"
          "${textfileDir}/${metricsBase}.prom"
        ];
      in
      lib.nameValuePair job.service {
        serviceConfig.ExecStopPost = lib.mkAfter [ "+${recordCommand}" ];
      }
    ) cfg.jobs;
  };
}
