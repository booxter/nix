{
  backups,
  configurations,
  hostName,
  lib,
}:
let
  destination = backups.destination;

  serverFor =
    destination:
    if builtins.hasAttr destination.server configurations then
      (configurations.${destination.server}.config or configurations.${destination.server})
      .host.backups.server
    else
      null;

  server = if destination == null then null else serverFor destination;
  valid = destination != null && server != null;

  resolveDestination =
    destination:
    let
      server = serverFor destination;
      local = destination.server == hostName;
    in
    {
      ingestUser = "restic-${hostName}";
      repositoryPath = "${server.repositoryRoot}/${destination.storageName}";
      transport = if local then "local" else "sftp";
      user = if local then "restic-cloud" else "root";
    };

in
{
  destination = if valid then resolveDestination destination else null;

  errors = {
    missingPublicKeys = lib.optional (
      destination != null && destination.server != hostName && destination.publicKey == null
    ) "${hostName} -> ${destination.server}";
    unknownServers = lib.optional (
      destination != null && !valid
    ) "${hostName} -> ${destination.server}";
  };
}
