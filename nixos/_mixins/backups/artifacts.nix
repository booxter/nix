{
  backupTopology,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./client/model.nix { inherit backupTopology config lib; };
  package = pkgs.callPackage ./pkgs/backup-artifact-tools { };
  databaseSources = builtins.filter (source: source.database != null) model.sourceEntries;

  artifactCommand =
    artifactConfig:
    utils.escapeSystemdExecArgs [
      (lib.getExe package)
      "--config"
      artifactConfig
    ];

  mkArtifactService = source: kind: artifactConfig: extraUnitConfig: {
    description = "Create a consistent ${source.title} ${kind} backup artifact";
    restartIfChanged = false;
    stopIfChanged = false;
    unitConfig = lib.mkMerge [
      {
        RequiresMountsFor = [ source.database.stagingDir ] ++ source.database.requiresMountsFor;
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

  mkEntry =
    source:
    let
      database = source.database;
      databaseName = if database.type == "sqlite" then source.name else database.name;
      service = "${databaseName}-backup";
      artifactConfig = (pkgs.formats.json { }).generate "${service}.json" (
        {
          kind = database.type;
          destinationDir = database.stagingDir;
        }
        // lib.optionalAttrs (database.type == "sqlite") {
          databasePath = database.path;
          extraCopies = map (copy: { inherit (copy) mode optional source; }) database.extraCopies;
        }
        // lib.optionalAttrs (database.type != "sqlite") {
          database = database.name;
          executable =
            if database.type == "postgresql" then
              lib.getExe' pkgs.postgresql "pg_dump"
            else
              lib.getExe' pkgs.mariadb "mariadb-dump";
        }
      );
      extraUnitConfig =
        if database.type == "postgresql" then
          { After = [ "postgresql.service" ]; }
        else if database.type == "mariadb" then
          {
            After = [ "mysql.service" ] ++ database.after;
            Requires = [ "mysql.service" ] ++ database.requires;
          }
        else
          lib.optionalAttrs (database.conditionPathExists != null) {
            ConditionPathExists = database.conditionPathExists;
          };
      kind =
        {
          sqlite = "SQLite";
          postgresql = "PostgreSQL";
          mariadb = "MariaDB";
        }
        .${database.type};
    in
    {
      name = service;
      value = mkArtifactService source kind artifactConfig extraUnitConfig;
    };
in
{
  config = lib.mkIf (databaseSources != [ ]) {
    systemd.services = builtins.listToAttrs (map mkEntry databaseSources);
  };
}
