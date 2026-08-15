{
  backupTopology,
  config,
  lib,
}:
let
  hostName = config.networking.hostName;
  cfg = config.host.backups;
in
rec {
  inherit cfg hostName;

  sources = lib.filterAttrs (_: source: source.enable) cfg.sources;
  sourceEntries = lib.mapAttrsToList (name: source: source // { inherit name; }) sources;
  destination =
    if cfg.destination != null && backupTopology.client.destination != null then
      cfg.destination
      // backupTopology.client.destination
      // {
        passwordFile =
          backupTopology.client.destination.passwordFile
            or config.sops.secrets.${passwordSecretFor backupTopology.client.destination}.path;
        identityFile =
          if backupTopology.client.destination.transport == "sftp" then
            backupTopology.client.destination.identityFile or config.sops.secrets.${sshKeySecret}.path
          else
            null;
        dependencyUnits =
          backupTopology.client.destination.dependencyUnits or [ "sops-install-secrets.service" ];
      }
    else
      null;

  jobName = destination.server;

  passwordSecretFor =
    destination:
    if destination.transport == "local" then
      "backup/restic/${hostName}/cloud/localPassword"
    else
      "backup/restic/local/password";
  sshKeySecret = "backup/restic/local/ssh/privateKey";

  directPathsFor =
    source: source.paths ++ lib.optionals (source.preparation != null) source.preparation.paths;
  pathCovers = root: path: path == root || lib.hasPrefix "${lib.removeSuffix "/" root}/" path;
  livePathsFor = selectedSources: lib.concatMap directPathsFor selectedSources;
  minimalPathsFor =
    selectedSources:
    let
      paths = lib.unique (livePathsFor selectedSources);
    in
    builtins.filter (path: !builtins.any (root: root != path && pathCovers root path) paths) paths;
  excludesFor = selectedSources: lib.unique (lib.concatMap (source: source.exclude) selectedSources);
  outputCoveredByJob =
    _: output: builtins.any (root: pathCovers root output) (livePathsFor sourceEntries);

  preparationFor =
    source:
    if source.preparation != null then
      {
        name = source.preparation.service;
        value = {
          service = source.preparation.service;
          title = "${source.title} Capture";
          paths = [ ];
        };
      }
    else if source.database != null then
      let
        database = source.database;
        serviceName = "${if database.type == "sqlite" then source.name else database.name}-backup";
      in
      {
        name = serviceName;
        value = {
          service = serviceName;
          title = "Create a consistent ${source.title} ${
            {
              sqlite = "SQLite";
              postgresql = "PostgreSQL";
              mariadb = "MariaDB";
            }
            .${database.type}
          } backup artifact";
          paths = lib.optional (!outputCoveredByJob source database.stagingDir) database.stagingDir;
        };
      }
    else
      null;
  preparations = builtins.listToAttrs (
    builtins.filter (entry: entry != null) (map preparationFor sourceEntries)
  );

  job =
    if sources == { } || destination == null then
      null
    else
      {
        name = jobName;
        title =
          if destination.transport == "local" then
            "${lib.strings.toSentenceCase hostName} Local Restic"
          else
            "Restic To ${lib.strings.toSentenceCase destination.server}";
        paths = minimalPathsFor sourceEntries;
        exclude = excludesFor sourceEntries;
        inherit destination preparations;
      };
}
