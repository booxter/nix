{
  config,
  lib,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  cloudGroup = "restic-cloud";
  cloudBucketName = "ihar-restic-prod";
  backupClients = {
    beast.publicKey = null;
    srvarr.publicKey = readPublicKey ../../public-keys/restic/srvarr.pub;
    org = {
      publicKey = readPublicKey ../../public-keys/restic/org.pub;
      # Repository names are durable storage identities. Keep the pre-rename
      # namespace so existing local and B2 snapshot history remains intact.
      storageName = "orgvm";
    };
    home.publicKey = readPublicKey ../../public-keys/restic/home.pub;
    pki.publicKey = readPublicKey ../../public-keys/restic/pki.pub;
  };
  storageName = name: backupClients.${name}.storageName or name;
  offloadUser = name: if name == "beast" then cloudGroup else "restic-${name}-offload";
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
in
{
  host.backups.server = {
    enable = true;
    repositoryRoot = "/volume2/backups/restic-prod/hosts";
    localClient = "beast";
    clients = lib.mapAttrs (name: client: {
      inherit (client) publicKey;
      storageName = storageName name;
      cloud = {
        enable = true;
        repository = "b2:${cloudBucketName}:hosts/${storageName name}";
        prefix = "hosts/${storageName name}";
        sourcePasswordFile = config.sops.secrets.${cloudSecret name "localPassword"}.path;
        passwordFile = config.sops.secrets.${cloudSecret name "password"}.path;
      };
    }) backupClients;
    cloud = {
      bucketName = cloudBucketName;
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
      ]) (builtins.attrNames backupClients)
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
