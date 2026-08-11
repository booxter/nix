{ config, lib, ... }:
let
  cfg = config.host.backups.server;
in
{
  assertions = lib.optionals cfg.enable (
    [
      {
        assertion = cfg.clients != { };
        message = "host.backups.server.clients must not be empty";
      }
      {
        assertion = cfg.localClient == null || builtins.hasAttr cfg.localClient cfg.clients;
        message = "host.backups.server.localClient must reference a configured client";
      }
      {
        assertion =
          cfg.localClient == null
          || !builtins.hasAttr cfg.localClient cfg.clients
          || cfg.clients.${cfg.localClient}.cloud.enable;
        message = "host.backups.server.localClient must have cloud offload enabled";
      }
    ]
    ++ lib.mapAttrsToList (name: client: {
      assertion =
        !client.cloud.enable
        || (
          client.cloud.repository != ""
          && client.cloud.sourcePasswordFile != ""
          && client.cloud.passwordFile != ""
          && (
            client.cloud.backend == "local"
            || (
              client.cloud.prefix != ""
              && cfg.cloud.bucketName != null
              && cfg.cloud.applicationKeyIdFile != null
              && cfg.cloud.applicationKeyFile != null
            )
          )
        );
      message = "host.backups.server.clients.${name}.cloud requires complete repository credentials";
    }) cfg.clients
  );
}
