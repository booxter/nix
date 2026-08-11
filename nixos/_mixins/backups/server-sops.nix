{
  config,
  lib,
  ...
}:
let
  cfg = config.host.backups.server;
  enabledCloudClients = lib.filterAttrs (_: client: client.cloud.enable) cfg.clients;
  credentialsEnabled = lib.any (client: client.cloud.backend != "local") (
    builtins.attrValues enabledCloudClients
  );
  offloadUser = name: if name == cfg.localClient then cfg.cloud.group else "restic-${name}-offload";
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
in
{
  config = lib.mkIf cfg.enable {
    host.backups.server.cloud = {
      dependencyUnits = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
    }
    // lib.optionalAttrs credentialsEnabled {
      applicationKeyIdFile = config.sops.secrets.${applicationKeyIdSecret}.path;
      applicationKeyFile = config.sops.secrets.${applicationKeySecret}.path;
    };

    sops.secrets =
      builtins.listToAttrs (
        lib.concatMap (name: [
          {
            name = cloudSecret name "localPassword";
            value = {
              owner = offloadUser name;
              group = offloadUser name;
              mode = "0400";
            };
          }
          {
            name = cloudSecret name "password";
            value = {
              owner = offloadUser name;
              group = offloadUser name;
              mode = "0400";
            };
          }
        ]) (builtins.attrNames enabledCloudClients)
      )
      // lib.optionalAttrs credentialsEnabled {
        ${applicationKeyIdSecret} = {
          group = cfg.cloud.group;
          mode = "0440";
        };
        ${applicationKeySecret} = {
          group = cfg.cloud.group;
          mode = "0440";
        };
      };
  };
}
