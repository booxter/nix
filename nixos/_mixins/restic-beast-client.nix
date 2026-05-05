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
    # Run after the 03:30±15m upgrade/reboot work has settled.
    OnCalendar = "04:30";
    RandomizedDelaySec = "15m";
  };
  defaultPreBackupTimerConfig = {
    OnCalendar = "04:15";
    RandomizedDelaySec = "0";
  };
  localSshKey = config.sops.secrets.${localSshKeySecret}.path;
  preBackupServiceNames = builtins.attrNames cfg.preBackupServices;
  reapResticSshHelper = pkgs.writeShellApplication {
    name = "reap-restic-sftp-ssh-helper";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      set -euo pipefail

      cgroup_path="$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)"
      procs_file="/sys/fs/cgroup''${cgroup_path}/cgroup.procs"

      [ -r "$procs_file" ] || exit 0

      while read -r pid; do
        [ -n "$pid" ] || continue
        [ "$pid" = "$$" ] && continue

        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [ "$comm" = "ssh" ] || continue

        echo "reaping leftover restic ssh helper pid $pid"
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
      done < "$procs_file"
    '';
  };
in
{
  options.host.backups.beast = {
    enable = lib.mkEnableOption "restic backups pushed over SFTP to beast";

    repoName = lib.mkOption {
      type = lib.types.str;
      example = "orgvm";
      description = "Repository name under /volume2/backups/restic-prod/hosts on beast.";
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

            script = lib.mkOption {
              type = package;
              description = "Executable package to run before restic starts.";
            };

            timerConfig = lib.mkOption {
              type = attrsOf anything;
              default = defaultPreBackupTimerConfig;
              description = "Timer settings for this generated pre-backup timer.";
            };

            user = lib.mkOption {
              type = str;
              default = "root";
              description = "User to run the pre-backup service as.";
            };

            group = lib.mkOption {
              type = str;
              default = "root";
              description = "Group to run the pre-backup service as.";
            };

            serviceConfig = lib.mkOption {
              type = attrsOf anything;
              default = { };
              description = "Extra serviceConfig fields merged into the generated oneshot.";
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
          repository = "sftp:restic-${cfg.repoName}@beast:/volume2/backups/restic-prod/hosts/${cfg.repoName}";
        }
        // lib.optionalAttrs (cfg.exclude != [ ]) {
          inherit (cfg) exclude;
        };

        systemd.services.restic-backups-beast = {
          postStop = lib.mkAfter ''
            ${lib.getExe reapResticSshHelper}
          '';
        }
        // lib.optionalAttrs (preBackupServiceNames != [ ]) {
          after = map (name: "${name}.service") preBackupServiceNames;
          wants = map (name: "${name}.service") preBackupServiceNames;
        };
      }

      {
        systemd.services = builtins.mapAttrs (name: service: {
          inherit (service) description unitConfig;
          before = [ "restic-backups-beast.service" ];
          serviceConfig = {
            Type = "oneshot";
            User = service.user;
            Group = service.group;
            ExecStart = lib.getExe service.script;
          }
          // service.serviceConfig;
        }) cfg.preBackupServices;

        systemd.timers = builtins.mapAttrs (_: service: {
          wantedBy = [ "timers.target" ];
          inherit (service) timerConfig;
        }) cfg.preBackupServices;
      }
    ]
  );
}
