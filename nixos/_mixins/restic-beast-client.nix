{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.backups.beast;
  localPasswordSecret = "backup/restic/local/password";
  localSshKeySecret = "backup/restic/local/ssh/privateKey";
  defaultPruneOpts = [
    "--keep-daily 7"
    "--keep-weekly 8"
    "--keep-monthly 6"
  ];
  defaultBackupTimerConfig = {
    # Default local backup timer; keep this offset from auto-upgrade windows.
    OnCalendar = "04:45";
    RandomizedDelaySec = "5m";
  };
  defaultPreBackupTimerConfig = {
    OnCalendar = "04:30";
    RandomizedDelaySec = "0";
  };
  localSshKey = config.sops.secrets.${localSshKeySecret}.path;
  preBackupServiceNames = builtins.attrNames cfg.preBackupServices;
  resticClientTools = pkgs.callPackage ./restic-beast-client/pkgs/restic-client-tools { };
in
{
  options.host.backups.beast = {
    enable = lib.mkEnableOption "restic backups pushed over SFTP to beast";

    clientName = lib.mkOption {
      type = lib.types.str;
      example = "org";
      description = "Client account name used to connect to the restic backup server on beast.";
    };

    storageName = lib.mkOption {
      type = lib.types.str;
      default = cfg.clientName;
      example = "orgvm";
      description = "Durable repository name under /volume2/backups/restic-prod/hosts on beast.";
    };

    paths = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "/var/lib/vikunja/files" ];
      description = "Paths to include in the restic backup.";
    };

    exclude = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Restic exclude globs for this backup.";
    };

    initialize = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to initialize the beast repository automatically if it does not exist yet.";
    };

    pruneOpts = lib.mkOption {
      type = with lib.types; listOf str;
      default = defaultPruneOpts;
      description = "Restic retention policy flags passed to forget --prune.";
    };

    timerConfig = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = defaultBackupTimerConfig;
      description = "Timer settings for the generated restic-backups-beast.timer.";
    };

    preBackupServices = lib.mkOption {
      type =
        with lib.types;
        attrsOf (submodule {
          options = {
            description = lib.mkOption {
              type = str;
              description = "systemd description for this pre-backup oneshot.";
            };

            execStart = lib.mkOption {
              type = str;
              description = "Escaped systemd command for the pre-backup service.";
            };

            timerConfig = lib.mkOption {
              type = attrsOf anything;
              default = defaultPreBackupTimerConfig;
              description = "Timer settings for this generated pre-backup timer.";
            };

            unitConfig = lib.mkOption {
              type = attrsOf anything;
              default = { };
              description = "Extra unitConfig fields merged into the generated oneshot.";
            };
          };
        });
      default = { };
      description = "Optional oneshot services to run before restic starts, each with its own timer.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.paths != [ ];
            message = "host.backups.beast.paths must be non-empty when host.backups.beast.enable = true.";
          }
        ];

        sops.secrets = {
          "${localPasswordSecret}" = { };
          "${localSshKeySecret}" = {
            owner = "root";
            group = "root";
            mode = "0400";
          };
        };

        programs.ssh.extraConfig = lib.mkAfter ''
          Host beast
            IdentityFile ${localSshKey}
            IdentitiesOnly yes
        '';

        services.restic.backups.beast = {
          inherit (cfg)
            initialize
            paths
            pruneOpts
            timerConfig
            ;
          passwordFile = config.sops.secrets.${localPasswordSecret}.path;
          repository = "sftp:restic-${cfg.clientName}@beast:/volume2/backups/restic-prod/hosts/${cfg.storageName}";
        }
        // lib.optionalAttrs (cfg.exclude != [ ]) {
          inherit (cfg) exclude;
        };

        systemd.services.restic-backups-beast = {
          # Run after the upstream restic include-file cleanup but before the
          # mkAfter backup-metrics recorder observes the final unit result.
          serviceConfig.ExecStopPost = lib.mkOrder 1400 [ (lib.getExe resticClientTools) ];
        }
        // lib.optionalAttrs (preBackupServiceNames != [ ]) {
          after = map (name: "${name}.service") preBackupServiceNames;
          requires = map (name: "${name}.service") preBackupServiceNames;
        };

        host.observability.backupMetrics.jobs = {
          "restic-beast-local" = {
            service = "restic-backups-beast";
            title = "Restic To Beast";
            phase = "local";
          };
        }
        // builtins.mapAttrs (name: service: {
          service = name;
          title = service.description;
          phase = "prep";
        }) cfg.preBackupServices;
      }

      {
        systemd.services = builtins.mapAttrs (_: service: {
          inherit (service) description unitConfig;
          before = [ "restic-backups-beast.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = "root";
            Group = "root";
            ExecStart = service.execStart;
          };
        }) cfg.preBackupServices;

        systemd.timers = builtins.mapAttrs (_: service: {
          wantedBy = [ "timers.target" ];
          inherit (service) timerConfig;
        }) cfg.preBackupServices;
      }
    ]
  );
}
