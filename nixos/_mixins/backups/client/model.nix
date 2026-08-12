{ config, lib }:
let
  hostName = config.networking.hostName;
  cfg = config.host.backups;
in
rec {
  inherit cfg hostName;

  sources = lib.filterAttrs (_: source: source.enable) cfg.sources;
  sourceEntries = lib.mapAttrsToList (name: source: source // { inherit name; }) sources;
  sourcesByDestination = lib.groupBy (source: source.destination) sourceEntries;
  activeDestinations = lib.mapAttrs (name: resolved: cfg.destinations.${name} // resolved) (
    lib.filterAttrs (name: _: builtins.hasAttr name sourcesByDestination) cfg.internal.destinations
  );

  destinationFor =
    source: cfg.destinations.${source.destination} // cfg.internal.destinations.${source.destination};
  jobNameForDestination =
    name: destination:
    if name == "primary" then destination.server else "${destination.server}-${name}";
  jobNameFor = source: jobNameForDestination source.destination (destinationFor source);

  secretSuffix = name: lib.optionalString (name != "primary") "/${name}";
  passwordSecretFor =
    name: destination:
    if destination.transport == "local" then
      "backup/restic/${hostName}/cloud/localPassword"
    else
      "backup/restic/local/password${secretSuffix name}";
  sshKeySecretFor = name: "backup/restic/local/ssh/privateKey${secretSuffix name}";

  directPathsFor =
    source:
    source.paths
    ++ lib.optionals (source.capture.type == "unit") source.capture.unit.outputPaths
    ++ lib.optionals (source.capture.type == "scheduled") source.capture.scheduled.outputPaths;
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
    source: output:
    builtins.any (root: pathCovers root output) (
      livePathsFor sourcesByDestination.${source.destination}
    );
}
