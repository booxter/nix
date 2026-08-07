{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.backups.jobs;
  inherit (utils.systemdUtils.unitOptions) unitOption;
  positiveInt = lib.types.addCheck lib.types.int (value: value > 0);
  resticServiceName = name: "restic-backups-${name}";
  sshHostAlias = name: "restic-backup-${name}";

  preparationModule =
    { name, ... }:
    {
      options = {
        service = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Systemd service name, without the .service suffix.";
        };

        title = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Human-readable preparation name used by backup monitoring.";
        };

        paths = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Paths produced by this preparation and included in the Restic job.";
        };
      };
    };

  repositoryModule = {
    options = {
      type = lib.mkOption {
        type = lib.types.enum [
          "local"
          "sftp"
        ];
        description = "Restic repository transport.";
      };

      path = lib.mkOption {
        type = lib.types.str;
        description = "Local or remote absolute repository path.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.str;
        description = "File containing the Restic repository password.";
      };

      dependencyUnits = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Units that must start before repository credentials are available.";
      };

      sftp = {
        host = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "SSH host used by an SFTP repository.";
        };

        user = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "SSH user used by an SFTP repository.";
        };

        identityFile = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "SSH private key used by an SFTP repository.";
        };

        port = lib.mkOption {
          type = with lib.types; nullOr port;
          default = null;
          description = "Optional SSH port used by an SFTP repository.";
        };
      };
    };
  };

  jobModule =
    { name, ... }:
    {
      options = {
        title = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Human-readable backup job name used by monitoring.";
        };

        repository = lib.mkOption {
          type = lib.types.submodule repositoryModule;
          description = "Restic repository configuration.";
        };

        paths = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Paths included in the Restic backup.";
        };

        exclude = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Restic exclude patterns.";
        };

        preparations = lib.mkOption {
          type = with lib.types; attrsOf (submodule preparationModule);
          default = { };
          description = "Services that must complete before the Restic job starts.";
        };

        initialize = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether Restic initializes a missing repository.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = "root";
          description = "User that runs the Restic job.";
        };

        timerConfig = lib.mkOption {
          type = with lib.types; nullOr (attrsOf unitOption);
          default = {
            OnCalendar = "04:45";
            RandomizedDelaySec = "5m";
            Persistent = true;
          };
          description = "Timer configuration for the complete backup pipeline.";
        };

        retention = {
          daily = lib.mkOption {
            type = positiveInt;
            default = 7;
          };

          weekly = lib.mkOption {
            type = positiveInt;
            default = 8;
          };

          monthly = lib.mkOption {
            type = positiveInt;
            default = 6;
          };
        };

        check = {
          enable = lib.mkEnableOption "Restic repository checks after backup";

          options = lib.mkOption {
            type = with lib.types; listOf str;
            default = [ ];
            description = "Arguments passed to restic check.";
          };
        };
      };
    };

  preparationPaths =
    job: lib.concatMap (preparation: preparation.paths) (builtins.attrValues job.preparations);
  preparationUnits =
    job: map (preparation: "${preparation.service}.service") (builtins.attrValues job.preparations);
  repositoryLocation =
    name: repository:
    if repository.type == "local" then
      repository.path
    else
      "sftp:${repository.sftp.user}@${sshHostAlias name}:${repository.path}";
  resticJobs = lib.mapAttrs (name: job: {
    inherit (job)
      exclude
      initialize
      timerConfig
      user
      ;
    paths = lib.unique (job.paths ++ preparationPaths job);
    passwordFile = job.repository.passwordFile;
    repository = repositoryLocation name job.repository;
    pruneOpts = [
      "--keep-daily ${toString job.retention.daily}"
      "--keep-weekly ${toString job.retention.weekly}"
      "--keep-monthly ${toString job.retention.monthly}"
    ];
    runCheck = job.check.enable;
    checkOpts = job.check.options;
  }) cfg;
  sftpJobs = lib.filterAttrs (_: job: job.repository.type == "sftp") cfg;
in
{
  options.host.backups.jobs = lib.mkOption {
    type = with lib.types; attrsOf (submodule jobModule);
    default = { };
    description = "Scheduled Restic backup pipelines.";
  };

  config = lib.mkIf (cfg != { }) {
    assertions = lib.concatLists (
      lib.mapAttrsToList (name: job: [
        {
          assertion = job.paths != [ ] || preparationPaths job != [ ];
          message = "host.backups.jobs.${name} must include at least one path";
        }
        {
          assertion =
            job.repository.type != "sftp"
            || (
              job.repository.sftp.host != null
              && job.repository.sftp.user != null
              && job.repository.sftp.identityFile != null
            );
          message = "host.backups.jobs.${name} requires complete SFTP settings";
        }
      ]) cfg
    );

    services.restic.backups = resticJobs;

    programs.ssh.extraConfig = lib.mkAfter (
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: job: ''
          Host ${sshHostAlias name}
            HostName ${job.repository.sftp.host}
            HostKeyAlias ${job.repository.sftp.host}
            IdentityFile ${job.repository.sftp.identityFile}
            IdentitiesOnly yes
            BatchMode yes
            ${lib.optionalString (
              job.repository.sftp.port != null
            ) "Port ${toString job.repository.sftp.port}"}
        '') sftpJobs
      )
    );

    systemd.services = lib.mapAttrs' (
      name: job:
      let
        serviceName = resticServiceName name;
        preparations = preparationUnits job;
        credentialUnits = job.repository.dependencyUnits;
      in
      lib.nameValuePair serviceName {
        wants = credentialUnits;
        after = credentialUnits ++ preparations;
        requires = preparations;
      }
    ) cfg;

    host.observability.backupMetrics.jobs = lib.mkMerge (
      lib.mapAttrsToList (
        name: job:
        {
          "restic-${name}" = {
            service = resticServiceName name;
            title = job.title;
            phase = "local";
          };
        }
        // builtins.mapAttrs (_: preparation: {
          inherit (preparation) service title;
          phase = "prep";
        }) job.preparations
      ) cfg
    );
  };
}
