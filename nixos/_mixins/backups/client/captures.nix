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
          database = source.capture.database;
          common = {
            job = jobNameFor source;
            displayName = source.title;
            destinationDir = database.destinationDir;
            includeInJob = !outputCoveredByJob source database.destinationDir;
            inherit (database) requiresMountsFor;
          };
        in
        if source.capture.type == "sqlite" then
          {
            sqlite.${name} = common // {
              databasePath = database.path;
              inherit (database) conditionPathExists extraCopies;
            };
          }
        else if source.capture.type == "postgresql" then
          { postgresql.${database.name} = common; }
        else if source.capture.type == "mariadb" then
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
