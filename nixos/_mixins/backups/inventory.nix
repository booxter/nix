{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  realmName = config.host.realm;
  backup = hostInventory.realms.${realmName}.services.backups or null;
  serverHost = if backup == null then null else backup.server.host;
  isServer = serverHost == hostname;
  storage = if backup == null then null else backup.server.storage;
  serverStorage =
    if backup == null || !builtins.hasAttr serverHost hostInventory.storage.hosts then
      null
    else
      hostInventory.storage.hosts.${serverHost};
  volume =
    if serverStorage == null || !builtins.hasAttr storage.volume serverStorage.volumes then
      null
    else
      serverStorage.volumes.${storage.volume};
  mount =
    if volume == null || !builtins.hasAttr storage.mount volume.mounts then
      null
    else
      volume.mounts.${storage.mount};
  repositoryRoot = if mount == null then null else "${mount.mountPoint}/${storage.relativePath}";
  clients = if backup == null then { } else backup.clients;
  isClient = builtins.hasAttr hostname clients;
  localClient =
    if serverHost != null && builtins.hasAttr serverHost clients then serverHost else null;
  offsite = if backup == null then null else backup.offsite;
  cloudGroup = config.host.backups.server.cloud.group;
  storageName = name: clients.${name}.storageName or name;
  clientRepositoryPath =
    if !isClient || repositoryRoot == null then "" else "${repositoryRoot}/${storageName hostname}";
  offloadUser = name: if name == localClient then cloudGroup else "restic-${name}-offload";
  cloudSecret = name: field: "backup/restic/${name}/cloud/${field}";
  applicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  applicationKeySecret = "backup/restic/cloud/b2/applicationKey";
  clientNames = builtins.attrNames clients;
  unknownClientNames = builtins.filter (
    name: !builtins.hasAttr name hostInventory.nixosHosts
  ) clientNames;
  crossRealmClientNames = builtins.filter (
    name:
    builtins.hasAttr name hostInventory.nixosHosts
    && hostInventory.nixosHosts.${name}.realm != realmName
  ) clientNames;
  missingPublicKeyClientNames = builtins.filter (
    name: name != localClient && (clients.${name}.publicKey or null) == null
  ) clientNames;
in
{
  options.host.backups = {
    destinationJob = lib.mkOption {
      type = lib.types.str;
      default = if serverHost == null then "" else serverHost;
      readOnly = true;
      internal = true;
      description = "Backup job selected by the realm backup policy.";
    };

    client = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = isClient;
        readOnly = true;
        internal = true;
        description = "Whether this host participates in its realm backup policy.";
      };

      isLocal = lib.mkOption {
        type = lib.types.bool;
        default = isClient && hostname == localClient;
        readOnly = true;
        internal = true;
        description = "Whether this host writes directly to its repository on the backup server.";
      };

      repositoryPath = lib.mkOption {
        type = lib.types.str;
        default = clientRepositoryPath;
        readOnly = true;
        internal = true;
        description = "Repository path assigned to this backup client.";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.optionals (backup != null) [
        {
          assertion = builtins.hasAttr serverHost hostInventory.nixosHosts;
          message = "Backup server '${serverHost}' must be a managed NixOS host";
        }
        {
          assertion =
            !builtins.hasAttr serverHost hostInventory.nixosHosts
            || hostInventory.nixosHosts.${serverHost}.realm == realmName;
          message = "Backup server '${serverHost}' must belong to realm '${realmName}'";
        }
        {
          assertion = unknownClientNames == [ ];
          message = "Backup clients must be managed NixOS hosts: ${lib.concatStringsSep ", " unknownClientNames}";
        }
        {
          assertion = crossRealmClientNames == [ ];
          message = "Backup clients must belong to realm '${realmName}': ${lib.concatStringsSep ", " crossRealmClientNames}";
        }
        {
          assertion = missingPublicKeyClientNames == [ ];
          message = "Remote backup clients require SSH public keys: ${lib.concatStringsSep ", " missingPublicKeyClientNames}";
        }
        {
          assertion = mount != null;
          message = "Backup server storage must reference an existing inventory mount";
        }
        {
          assertion = offsite.provider == "b2";
          message = "Unsupported backup offsite provider '${offsite.provider}'";
        }
        {
          assertion = config.host.backups.jobs == { } || config.host.backups.client.enable;
          message = "Host '${hostname}' defines backup jobs but is not a backup client in realm '${realmName}'";
        }
        {
          assertion = lib.all (name: name == config.host.backups.destinationJob) (
            builtins.attrNames config.host.backups.jobs
          );
          message = "Host '${hostname}' defines a backup job outside its realm backup policy";
        }
      ];
    }
    (lib.mkIf isServer {
      host.backups.server = {
        enable = true;
        inherit localClient repositoryRoot;
        clients = lib.mapAttrs (name: client: {
          publicKey = client.publicKey or null;
          storageName = storageName name;
          cloud = {
            enable = true;
            repository = "b2:${offsite.bucketName}:${offsite.repositoryPrefix}/${storageName name}";
            prefix = "${offsite.repositoryPrefix}/${storageName name}";
            sourcePasswordFile = config.sops.secrets.${cloudSecret name "localPassword"}.path;
            passwordFile = config.sops.secrets.${cloudSecret name "password"}.path;
          };
        }) clients;
        cloud = {
          inherit (offsite) b2Connections bucketName packSizeMib;
          applicationKeyIdFile = config.sops.secrets.${applicationKeyIdSecret}.path;
          applicationKeyFile = config.sops.secrets.${applicationKeySecret}.path;
          dependencyUnits = [
            "network-online.target"
            "sops-install-secrets.service"
          ];
          requiredUnits = [ "qos-wan.service" ];
        };
      };

      host.qos.interfaces.wan = {
        device = config.host.network.primaryInterface;
        limits.cloud-backup = {
          rateMbit = offsite.rateMbit;
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
          ]) clientNames
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
    })
  ];
}
