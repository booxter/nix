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
    {
      assertion = client.errors.duplicateServers == [ ];
      message = "backup client may define only one destination per server: ${lib.concatStringsSep ", " client.errors.duplicateServers}";
    }
  ]
  ++ lib.optionals backups.server.enable [
    {
      assertion = server.errors.duplicateRepositoryPaths == [ ];
      message = "backup destinations resolve to duplicate repository paths: ${lib.concatStringsSep ", " server.errors.duplicateRepositoryPaths}";
    }
    {
      assertion = !server.errors.invalidB2Root;
      message = "B2 offsite repository root must contain its bucket name";
    }
    {
      assertion = !server.errors.multipleLocalClients;
      message = "backup server may have at most one local client";
    }
  ];
}
