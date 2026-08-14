{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    jobNameFor
    outputCoveredByJob
    sourceEntries
    sources
    ;
in
{
  config = lib.mkIf (sources != { }) {
    host.backups.artifacts = lib.mkMerge (
      map (
        source:
        let
          name = source.name;
          database = source.database;
          common = {
            job = jobNameFor source;
            displayName = source.title;
            destinationDir = database.stagingDir;
            includeInJob = !outputCoveredByJob source database.stagingDir;
            inherit (database) requiresMountsFor;
          };
        in
        if database == null then
          { }
        else if database.type == "sqlite" then
          {
            sqlite.${name} = common // {
              databasePath = database.path;
              inherit (database) conditionPathExists extraCopies;
            };
          }
        else if database.type == "postgresql" then
          { postgresql.${database.name} = common; }
        else if database.type == "mariadb" then
          {
            mariadb.${database.name} = common // {
              inherit (database) after requires;
            };
          }
        else
          { }
      ) sourceEntries
    );
  };
}
