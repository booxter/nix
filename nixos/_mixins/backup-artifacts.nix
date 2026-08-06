{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.backups.artifacts;
  package = pkgs.callPackage ./backup-artifacts/pkgs/backup-artifact-tools { };
  defaultTimerConfig = {
    OnCalendar = "04:30";
    RandomizedDelaySec = "0";
  };

  commonArtifactOptions =
    { name }:
    {
      displayName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Human-readable name used in the generated service description.";
      };

      destinationDir = lib.mkOption {
        type = lib.types.str;
        description = "Directory where the latest backup artifact is staged for restic.";
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

    };

  postgresqlArtifactModule =
    { name, ... }:
    {
      options = commonArtifactOptions { inherit name; };
    };

  mariadbArtifactModule =
    { name, ... }:
    {
      options = commonArtifactOptions { inherit name; } // {
        after = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Additional units that must start before the dump.";
        };

        requires = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Additional units required by the dump service.";
        };
      };
    };

  sqliteExtraCopyModule = {
    options = {
      source = lib.mkOption {
        type = lib.types.str;
        description = "Path to an additional file copied into the SQLite backup artifact.";
      };

      mode = lib.mkOption {
        type = lib.types.strMatching "^0[0-7]{3}$";
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
    { name, ... }:
    {
      options = commonArtifactOptions { inherit name; } // {
        databasePath = lib.mkOption {
          type = lib.types.str;
          description = "SQLite database path to back up with the native backup API.";
        };

        extraCopies = lib.mkOption {
          type = with lib.types; listOf (submodule sqliteExtraCopyModule);
          default = [ ];
          description = "Additional files copied into the same artifact directory.";
        };

        conditionPathExists = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Skip the backup service when this path does not exist.";
        };
      };
    };

  artifactCommand =
    artifactConfig:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
      "--config"
      artifactConfig
    ];

  mkArtifactService = artifact: kind: artifactConfig: extraUnitConfig: {
    description = "Create a consistent ${artifact.displayName} ${kind} backup artifact";
    timerConfig = defaultTimerConfig;
    unitConfig = lib.mkMerge [
      {
        RequiresMountsFor = [ artifact.destinationDir ] ++ artifact.requiresMountsFor;
      }
      extraUnitConfig
    ];
    execStart = artifactCommand artifactConfig;
  };

  mkPostgresqlService =
    name: artifact:
    let
      artifactConfig = (pkgs.formats.json { }).generate "${name}-backup.json" {
        kind = "postgresql";
        database = name;
        destinationDir = artifact.destinationDir;
        executable = lib.getExe' pkgs.postgresql "pg_dump";
      };
    in
    lib.nameValuePair "${name}-backup" (
      mkArtifactService artifact "PostgreSQL" artifactConfig { After = [ "postgresql.service" ]; }
    );

  mkMariadbService =
    name: artifact:
    let
      artifactConfig = (pkgs.formats.json { }).generate "${name}-backup.json" {
        kind = "mariadb";
        database = name;
        destinationDir = artifact.destinationDir;
        executable = lib.getExe' pkgs.mariadb "mariadb-dump";
      };
    in
    lib.nameValuePair "${name}-backup" (
      mkArtifactService artifact "MariaDB" artifactConfig {
        After = [ "mysql.service" ] ++ artifact.after;
        Requires = [ "mysql.service" ] ++ artifact.requires;
      }
    );

  mkSqliteService =
    name: artifact:
    let
      artifactConfig = (pkgs.formats.json { }).generate "${name}-backup.json" {
        kind = "sqlite";
        databasePath = artifact.databasePath;
        destinationDir = artifact.destinationDir;
        extraCopies = map (copy: { inherit (copy) mode optional source; }) artifact.extraCopies;
      };
    in
    lib.nameValuePair "${name}-backup" (
      mkArtifactService artifact "SQLite" artifactConfig (
        lib.optionalAttrs (artifact.conditionPathExists != null) {
          ConditionPathExists = artifact.conditionPathExists;
        }
      )
    );

  mariadbServices = lib.mapAttrsToList mkMariadbService cfg.mariadb;
  postgresqlServices = lib.mapAttrsToList mkPostgresqlService cfg.postgresql;
  sqliteServices = lib.mapAttrsToList mkSqliteService cfg.sqlite;
  hasArtifacts = cfg.mariadb != { } || cfg.postgresql != { } || cfg.sqlite != { };
  artifactPaths = lib.unique (
    lib.concatMap
      (
        artifacts:
        lib.concatLists (
          lib.mapAttrsToList (
            _: artifact: lib.optional artifact.includeInBeastBackup artifact.destinationDir
          ) artifacts
        )
      )
      [
        cfg.mariadb
        cfg.postgresql
        cfg.sqlite
      ]
  );
in
{
  options.host.backups.artifacts = {
    mariadb = lib.mkOption {
      type = with lib.types; attrsOf (submodule mariadbArtifactModule);
      default = { };
      description = "MariaDB backup artifacts generated before restic runs.";
    };

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
      preBackupServices = builtins.listToAttrs (mariadbServices ++ postgresqlServices ++ sqliteServices);
    };
  };
}
