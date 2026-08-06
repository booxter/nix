{
  config,
  hostInventory,
  lib,
  ...
}:
let
  backupInventory = hostInventory.backups;
  cloudGroup = "restic-cloud";
  inherit (backupInventory) clients;
  inherit (backupInventory.cloud) bucketName;
  offloadUser = name: if name == "beast" then cloudGroup else "restic-${name}-offload";
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
in
{
  host.backups.server = {
    enable = true;
    inherit (backupInventory.server) localClient repositoryRoot;
    clients = lib.mapAttrs (name: client: {
      inherit (client) publicKey storageName;
      cloud = {
        enable = true;
        repository = "b2:${bucketName}:hosts/${client.storageName}";
        prefix = "hosts/${client.storageName}";
        sourcePasswordFile = config.sops.secrets.${cloudSecret name "localPassword"}.path;
        passwordFile = config.sops.secrets.${cloudSecret name "password"}.path;
      };
    }) clients;
    cloud = {
      inherit bucketName;
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
