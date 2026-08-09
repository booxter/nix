{
  config,
  lib,
  ...
}:
let
  cfg = config.host.backups.server;
  enabledCloudClients = lib.filterAttrs (_: client: client.cloud.enable) cfg.clients;
  usageEnabled = lib.any (client: lib.hasPrefix "b2:" client.cloud.repository) (
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
    // lib.optionalAttrs usageEnabled {
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
      // lib.optionalAttrs usageEnabled {
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
