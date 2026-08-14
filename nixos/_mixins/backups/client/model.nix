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
      cfg.destination // backupTopology.client.destination
    else
      null;

  jobName = destination.server;
  jobNameFor = _: jobName;

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
}
