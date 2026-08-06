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

  commonArtifactOptions =
    { name }:
    {
      job = lib.mkOption {
        type = lib.types.str;
        description = "Backup job that consumes this artifact.";
      };

      displayName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Human-readable name used in the generated service description.";
      };

      destinationDir = lib.mkOption {
        type = lib.types.str;
        description = "Directory where the latest backup artifact is staged for Restic.";
      };

      requiresMountsFor = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = "Additional paths included in the generated unit's RequiresMountsFor.";
      };

      includeInJob = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether destinationDir is added to the consuming backup job.";
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
          description = "SQLite database path backed up with the native backup API.";
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
    restartIfChanged = false;
    stopIfChanged = false;
    unitConfig = lib.mkMerge [
      {
        RequiresMountsFor = [ artifact.destinationDir ] ++ artifact.requiresMountsFor;
      }
      extraUnitConfig
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = artifactCommand artifactConfig;
    };
  };

  mkPostgresqlEntry =
    name: artifact:
    let
      service = "${name}-backup";
      artifactConfig = (pkgs.formats.json { }).generate "${service}.json" {
        kind = "postgresql";
        database = name;
        destinationDir = artifact.destinationDir;
        executable = lib.getExe' pkgs.postgresql "pg_dump";
      };
    in
    {
      inherit artifact service;
      serviceConfig = mkArtifactService artifact "PostgreSQL" artifactConfig {
        After = [ "postgresql.service" ];
      };
    };

  mkMariadbEntry =
    name: artifact:
    let
      service = "${name}-backup";
      artifactConfig = (pkgs.formats.json { }).generate "${service}.json" {
        kind = "mariadb";
        database = name;
        destinationDir = artifact.destinationDir;
        executable = lib.getExe' pkgs.mariadb "mariadb-dump";
      };
    in
    {
      inherit artifact service;
      serviceConfig = mkArtifactService artifact "MariaDB" artifactConfig {
        After = [ "mysql.service" ] ++ artifact.after;
        Requires = [ "mysql.service" ] ++ artifact.requires;
      };
    };

  mkSqliteEntry =
    name: artifact:
    let
      service = "${name}-backup";
      artifactConfig = (pkgs.formats.json { }).generate "${service}.json" {
        kind = "sqlite";
        databasePath = artifact.databasePath;
        destinationDir = artifact.destinationDir;
        extraCopies = map (copy: { inherit (copy) mode optional source; }) artifact.extraCopies;
      };
    in
    {
      inherit artifact service;
      serviceConfig = mkArtifactService artifact "SQLite" artifactConfig (
        lib.optionalAttrs (artifact.conditionPathExists != null) {
          ConditionPathExists = artifact.conditionPathExists;
        }
      );
    };

  entries =
    (lib.mapAttrsToList mkMariadbEntry cfg.mariadb)
    ++ (lib.mapAttrsToList mkPostgresqlEntry cfg.postgresql)
    ++ (lib.mapAttrsToList mkSqliteEntry cfg.sqlite);
in
{
  options.host.backups.artifacts = {
    mariadb = lib.mkOption {
      type = with lib.types; attrsOf (submodule mariadbArtifactModule);
      default = { };
      description = "MariaDB backup artifacts generated before Restic runs.";
    };

    postgresql = lib.mkOption {
      type = with lib.types; attrsOf (submodule postgresqlArtifactModule);
      default = { };
      description = "PostgreSQL backup artifacts generated before Restic runs.";
    };

    sqlite = lib.mkOption {
      type = with lib.types; attrsOf (submodule sqliteArtifactModule);
      default = { };
      description = "SQLite backup artifacts generated before Restic runs.";
    };
  };

  config = lib.mkIf (entries != [ ]) {
    systemd.services = builtins.listToAttrs (
      map (entry: {
        name = entry.service;
        value = entry.serviceConfig;
      }) entries
    );

    host.backups.jobs = lib.mkMerge (
      map (entry: {
        ${entry.artifact.job}.preparations.${entry.service} = {
          service = entry.service;
          title = entry.serviceConfig.description;
          paths = lib.optional entry.artifact.includeInJob entry.artifact.destinationDir;
        };
      }) entries
    );
  };
}
