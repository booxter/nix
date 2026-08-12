{
  duplicateDestinationServers,
  duplicateRepositoryPaths,
  invalidB2Root,
  lib,
  localClients,
  missingPublicKeys,
  serverEnabled,
  unknownServers,
}:
{
  assertions = [
    {
      assertion = unknownServers == [ ];
      message = "backup destinations reference unknown or disabled servers: ${lib.concatStringsSep ", " unknownServers}";
    }
    {
      assertion = missingPublicKeys == [ ];
      message = "remote backup destinations require client public keys: ${lib.concatStringsSep ", " missingPublicKeys}";
    }
    {
      assertion = duplicateDestinationServers == [ ];
      message = "backup client may define only one destination per server: ${lib.concatStringsSep ", " duplicateDestinationServers}";
    }
  ]
  ++ lib.optionals serverEnabled [
    {
      assertion = duplicateRepositoryPaths == [ ];
      message = "backup destinations resolve to duplicate repository paths: ${lib.concatStringsSep ", " duplicateRepositoryPaths}";
    }
    {
      assertion = !invalidB2Root;
      message = "B2 offsite repository root must contain its bucket name";
    }
    {
      assertion = builtins.length localClients <= 1;
      message = "backup server may have at most one local client";
    }
  ];
}
