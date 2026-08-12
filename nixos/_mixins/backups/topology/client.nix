{
  backups,
  configurations,
  hostName,
  lib,
}:
let
  enabledDestinations = lib.filterAttrs (_: destination: destination.enable) backups.destinations;

  serverFor =
    destination:
    if builtins.hasAttr destination.server configurations then
      configurations.${destination.server}.config.host.backups.server
    else
      null;

  validDestinations = lib.filterAttrs (
    _: destination:
    let
      server = serverFor destination;
    in
    server != null && server.enable
  ) enabledDestinations;

  resolveDestination =
    _: destination:
    let
      server = serverFor destination;
      local = destination.server == hostName;
    in
    {
      ingestUser = "restic-${hostName}";
      repositoryPath = "${server.repositoryRoot}/${destination.storageName}";
      transport = if local then "local" else "sftp";
      user = if local then "restic-cloud" else destination.user;
    };

  duplicates =
    values:
    builtins.attrNames (
      lib.filterAttrs (_: group: builtins.length group > 1) (lib.groupBy (value: value) values)
    );

  unknownDestinations = lib.filterAttrs (
    _: destination:
    let
      server = serverFor destination;
    in
    server == null || !server.enable
  ) enabledDestinations;

  remoteDestinationsWithoutKeys = lib.filterAttrs (
    _: destination: destination.server != hostName && destination.publicKey == null
  ) enabledDestinations;
in
{
  destinations = lib.mapAttrs resolveDestination validDestinations;

  errors = {
    duplicateServers = duplicates (
      map (destination: destination.server) (builtins.attrValues enabledDestinations)
    );
    missingPublicKeys = lib.mapAttrsToList (
      name: destination: "${hostName}.${name} -> ${destination.server}"
    ) remoteDestinationsWithoutKeys;
    unknownServers = lib.mapAttrsToList (
      name: destination: "${hostName}.${name} -> ${destination.server}"
    ) unknownDestinations;
  };
}
