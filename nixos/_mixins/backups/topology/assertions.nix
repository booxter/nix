{
  backups,
  client,
  lib,
  server,
}:
{
  assertions = [
    {
      assertion = client.errors.unknownServers == [ ];
      message = "backup destinations reference unknown or disabled servers: ${lib.concatStringsSep ", " client.errors.unknownServers}";
    }
    {
      assertion = client.errors.missingPublicKeys == [ ];
      message = "remote backup destinations require client public keys: ${lib.concatStringsSep ", " client.errors.missingPublicKeys}";
    }
  ]
  ++ lib.optionals (backups.server != null) [
    {
      assertion = server.errors.duplicateRepositoryPaths == [ ];
      message = "backup destinations resolve to duplicate repository paths: ${lib.concatStringsSep ", " server.errors.duplicateRepositoryPaths}";
    }
    {
      assertion = !server.errors.multipleLocalClients;
      message = "backup server may have at most one local client";
    }
  ];
}
