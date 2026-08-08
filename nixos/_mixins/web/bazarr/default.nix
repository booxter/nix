{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.bazarr;
  hostCfg = config.host.bazarr;
  hostname = config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  service = hostInventory.servicesById.bazarr;
  instance = service.instances.${hostname} or { };
  account = hostInventory.serviceAccounts.bazarr;
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaGroup = mediaExport.sharedGroup;
  isMediaServer = mediaExport.server == hostname;
  stateDir = cfg.dataDir;
  user = "bazarr";
  enforceAuthCommand = utils.escapeSystemdExecArgs [
    (lib.getExe cfg.authConfig.package)
    "--config"
    "${stateDir}/config/config.yaml"
    "--uid"
    (toString account.uid)
    "--gid"
    (toString mediaGroup.gid)
  ];
in
{
  options = {
    host.bazarr.enable = lib.mkOption {
      type = lib.types.bool;
      default = service.owner == hostname;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns Bazarr to this host.";
    };

    services.bazarr = {
      mediaDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bazarr-media";
        description = "Local mount point for shared media storage.";
      };

      authConfig.package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./packages/bazarr-auth-config {
          atomicFileWrites = pkgs.atomic-file-writes;
        };
        description = "Package enforcing Bazarr reverse-proxy authentication.";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.hasAttr service.owner hostInventory.nixosHosts;
          message = "Bazarr owner '${service.owner}' must be a managed NixOS host";
        }
        {
          assertion = !hostCfg.enable || hostInventory.nixosHosts.${service.owner}.realm == config.host.realm;
          message = "Bazarr owner '${service.owner}' must belong to realm '${config.host.realm}'";
        }
      ];
    }

    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = instance ? dataDir && instance ? mediaDir;
          message = "The Bazarr inventory instance must define dataDir and mediaDir.";
        }
        {
          assertion = builtins.elem hostname mediaExport.clients;
          message = "The Bazarr owner must be an authorized media NFS client.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Bazarr owner must be a declared backup client.";
        }
      ];

      services.bazarr = {
        enable = true;
        dataDir = instance.dataDir;
        mediaDir = instance.mediaDir;
        group = mediaGroup.name;
        inherit user;
      };

      host.nfs.mounts = lib.mkIf (!isMediaServer) {
        media = instance.mediaDir;
      };

      systemd.tmpfiles.rules = [
        "d '${stateDir}' 0700 ${user} root - -"
      ];

      users.users.${user} = {
        extraGroups = lib.mkForce [ mediaGroup.name ];
        home = lib.mkForce "/var/empty";
        isSystemUser = true;
        uid = account.uid;
      };

      systemd.services.bazarr = {
        unitConfig.RequiresMountsFor = instance.mediaDir;
        serviceConfig = {
          ExecStartPre = "+${enforceAuthCommand}";
          UMask = lib.mkForce "0002";
        };
      };

      host.internalService.services.bazarr = {
        enable = true;
        upstream = "http://127.0.0.1:${toString cfg.listenPort}";
      };

      host.backups.jobs.${backupJob}.paths = [ stateDir ];
    })
  ];
}
