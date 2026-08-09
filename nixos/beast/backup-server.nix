{
  config,
  lib,
  ...
}:
let
  cloudGroup = "restic-cloud";
  clients = config.host.backups.server.clients;
  offloadUser = name: if name == "beast" then cloudGroup else "restic-${name}-offload";
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
in
{
  host.backups.server = {
    cloud = {
      applicationKeyIdFile = config.sops.secrets.${applicationKeyIdSecret}.path;
      applicationKeyFile = config.sops.secrets.${applicationKeySecret}.path;
      # Keep uploads serialized and packs small so shaped B2 requests finish
      # without timing out mid-pack.
      b2Connections = 1;
      packSizeMib = 4;
      dependencyUnits = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      requiredUnits = [ "qos-wan.service" ];
    };
  };

  host.qos.interfaces.wan = {
    device = "enp6s0";
    limits.cloud-backup = {
      rateMbit = 10;
      match.users = config.host.backups.server.generated.offloadUsers;
    };
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
      ]) (builtins.attrNames clients)
    )
    // {
      ${applicationKeyIdSecret} = {
        group = cloudGroup;
        mode = "0440";
      };
      ${applicationKeySecret} = {
        group = cloudGroup;
        mode = "0440";
      };
    };
}
