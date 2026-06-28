{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.backups.artifacts;
  shellArg = lib.escapeShellArg;

  defaultTimerConfig = {
    OnCalendar = "04:30";
    RandomizedDelaySec = "0";
  };

  commonArtifactOptions =
    {
      name,
      config,
      kind,
      defaultDestinationFile,
    }:
    {
      serviceName = lib.mkOption {
        type = lib.types.str;
        default = "${name}-backup";
        description = "Name of the generated pre-backup systemd service.";
      };

      displayName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Human-readable service name used in the generated description.";
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = "Create a consistent ${config.displayName} ${kind} backup artifact";
        description = "systemd description for the generated pre-backup service.";
      };

      destinationDir = lib.mkOption {
        type = lib.types.str;
        description = "Directory where the latest backup artifact is staged for restic.";
      };

      destinationFile = lib.mkOption {
        type = lib.types.str;
        default = defaultDestinationFile;
        description = "Filename for the primary backup artifact inside destinationDir.";
      };

      requiresMountsFor = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Additional paths to include in the generated unit's RequiresMountsFor.";
      };

      includeInBeastBackup = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether destinationDir is appended to host.backups.beast.paths.";
      };

      timerConfig = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = defaultTimerConfig;
        description = "Timer settings for the generated pre-backup timer.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "User to run the pre-backup service as.";
      };

      group = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Group to run the pre-backup service as.";
      };

      serviceConfig = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = { };
        description = "Extra serviceConfig fields merged into the generated oneshot.";
      };

      unitConfig = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = { };
        description = "Extra unitConfig fields merged into the generated oneshot.";
      };
    };

  postgresqlArtifactModule =
    { name, config, ... }:
    {
      options =
        commonArtifactOptions {
          inherit name config;
          kind = "PostgreSQL";
          defaultDestinationFile = "${name}.dump";
        }
        // {
          database = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "PostgreSQL database to dump with pg_dump.";
          };

          postgresUser = lib.mkOption {
            type = lib.types.str;
            default = "postgres";
            description = "Local user used to run pg_dump.";
          };
        };
    };

  sqliteExtraCopyModule =
    { config, ... }:
    {
      options = {
        source = lib.mkOption {
          type = lib.types.str;
          description = "Path to an additional file copied into the SQLite backup artifact.";
        };

        destination = lib.mkOption {
          type = lib.types.str;
          default = builtins.baseNameOf config.source;
          description = "Relative destination path inside destinationDir.";
        };

        mode = lib.mkOption {
          type = lib.types.str;
          default = "0640";
          description = "Install mode used when staging this file.";
        };

        optional = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether a missing source file is ignored.";
        };
      };
    };

  sqliteArtifactModule =
    { name, config, ... }:
    {
      options =
        commonArtifactOptions {
          inherit name config;
          kind = "SQLite";
          defaultDestinationFile = builtins.baseNameOf config.databasePath;
        }
        // {
          databasePath = lib.mkOption {
            type = lib.types.str;
            description = "SQLite database path to back up with sqlite3 .backup.";
          };

          extraCopies = lib.mkOption {
            type = with lib.types; listOf (submodule sqliteExtraCopyModule);
            default = [ ];
            description = "Additional files copied into the same artifact directory.";
          };
        };
    };

  mkPostgresqlScript =
    artifact:
    pkgs.writeShellApplication {
      name = artifact.serviceName;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.postgresql
        pkgs.util-linux
      ];
      text = ''
        set -euo pipefail

        dst_dir=${shellArg artifact.destinationDir}
        dst_file=${shellArg artifact.destinationFile}
        backup_root="$(dirname "$dst_dir")"

        install -d -m 0750 "$backup_root"
        tmp_dir="$(mktemp -d "$backup_root/.tmp.XXXXXX")"
        trap 'rm -rf "$tmp_dir"' EXIT

        install -d -m 0750 "$dst_dir"

        runuser -u ${shellArg artifact.postgresUser} -- pg_dump --format=custom ${shellArg artifact.database} > "$tmp_dir/$dst_file"
        date --iso-8601=seconds > "$tmp_dir/created-at.txt"

        mv "$tmp_dir/$dst_file" "$dst_dir/$dst_file"
        mv "$tmp_dir/created-at.txt" "$dst_dir/created-at.txt"
      '';
    };

  mkExtraCopyScript = copy: ''
    copy_src=${shellArg copy.source}
    copy_dst=${shellArg copy.destination}
    copy_mode=${shellArg copy.mode}
    if [ -f "$copy_src" ]; then
      install -d -m 0750 "$(dirname "$tmp_dir/$copy_dst")"
      install -m "$copy_mode" "$copy_src" "$tmp_dir/$copy_dst"
    ${
      if copy.optional then
        "fi"
      else
        ''
          else
            echo "missing extra backup file at $copy_src" >&2
            exit 1
          fi
        ''
    }
  '';

  mkExtraMoveScript = copy: ''
    copy_dst=${shellArg copy.destination}
    if [ -f "$tmp_dir/$copy_dst" ]; then
      install -d -m 0750 "$(dirname "$dst_dir/$copy_dst")"
      mv "$tmp_dir/$copy_dst" "$dst_dir/$copy_dst"
    fi
  '';

  mkSqliteScript =
    artifact:
    pkgs.writeShellApplication {
      name = artifact.serviceName;
      runtimeInputs = [
        pkgs.coreutils
        pkgs.sqlite
      ];
      text = ''
        set -euo pipefail

        src_db=${shellArg artifact.databasePath}
        dst_dir=${shellArg artifact.destinationDir}
        dst_file=${shellArg artifact.destinationFile}
        backup_root="$(dirname "$dst_dir")"

        install -d -m 0750 "$backup_root"
        tmp_dir="$(mktemp -d "$backup_root/.tmp.XXXXXX")"
        trap 'rm -rf "$tmp_dir"' EXIT

        install -d -m 0750 "$dst_dir"

        if [ ! -f "$src_db" ]; then
          echo "missing ${artifact.displayName} database at $src_db" >&2
          exit 1
        fi

        sqlite3 "$src_db" ".backup '$tmp_dir/$dst_file'"
        ${lib.concatMapStrings mkExtraCopyScript artifact.extraCopies}
        date --iso-8601=seconds > "$tmp_dir/created-at.txt"

        mv "$tmp_dir/$dst_file" "$dst_dir/$dst_file"
        ${lib.concatMapStrings mkExtraMoveScript artifact.extraCopies}
        mv "$tmp_dir/created-at.txt" "$dst_dir/created-at.txt"
      '';
    };

  mkPostgresqlService =
    _: artifact:
    lib.nameValuePair artifact.serviceName {
      inherit (artifact)
        description
        group
        serviceConfig
        timerConfig
        user
        ;
      script = mkPostgresqlScript artifact;
      unitConfig = lib.mkMerge [
        {
          After = [ "postgresql.service" ];
          RequiresMountsFor = [ artifact.destinationDir ] ++ artifact.requiresMountsFor;
        }
        artifact.unitConfig
      ];
    };

  mkSqliteService =
    _: artifact:
    lib.nameValuePair artifact.serviceName {
      inherit (artifact)
        description
        group
        serviceConfig
        timerConfig
        user
        ;
      script = mkSqliteScript artifact;
      unitConfig = lib.mkMerge [
        {
          RequiresMountsFor = [ artifact.destinationDir ] ++ artifact.requiresMountsFor;
        }
        artifact.unitConfig
      ];
    };

  postgresqlServices = lib.mapAttrsToList mkPostgresqlService cfg.postgresql;
  sqliteServices = lib.mapAttrsToList mkSqliteService cfg.sqlite;
  hasArtifacts = cfg.postgresql != { } || cfg.sqlite != { };
  artifactPaths = lib.unique (
    (lib.concatLists (
      lib.mapAttrsToList (
        _: artifact: lib.optional artifact.includeInBeastBackup artifact.destinationDir
      ) cfg.postgresql
    ))
    ++ (lib.concatLists (
      lib.mapAttrsToList (
        _: artifact: lib.optional artifact.includeInBeastBackup artifact.destinationDir
      ) cfg.sqlite
    ))
  );
in
{
  options.host.backups.artifacts = {
    postgresql = lib.mkOption {
      type = with lib.types; attrsOf (submodule postgresqlArtifactModule);
      default = { };
      description = "PostgreSQL backup artifacts generated before restic runs.";
    };

    sqlite = lib.mkOption {
      type = with lib.types; attrsOf (submodule sqliteArtifactModule);
      default = { };
      description = "SQLite backup artifacts generated before restic runs.";
    };
  };

  config = lib.mkIf hasArtifacts {
    host.backups.beast = {
      paths = lib.mkBefore artifactPaths;
      preBackupServices = builtins.listToAttrs (postgresqlServices ++ sqliteServices);
    };
  };
}
