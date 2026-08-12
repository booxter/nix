{
  config,
  lib,
  ...
}:
let
  cfg = config.host.backups.server;
  cloudGroup = "restic-cloud";
  enabledCloudClients = lib.filterAttrs (_: client: client.cloud.enable) cfg.repositories;
  credentialsEnabled = lib.any (client: client.cloud.backend != "local") (
    builtins.attrValues enabledCloudClients
  );
  offloadUser = name: if name == cfg.localClient then cloudGroup else "restic-${name}-offload";
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
in
{
  config = lib.mkIf cfg.enable {
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
          group = cloudGroup;
          mode = "0440";
        };
        ${applicationKeySecret} = {
          group = cloudGroup;
          mode = "0440";
        };
      };
  };
}
