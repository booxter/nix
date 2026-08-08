{
  config,
  hostInventory,
  lib,
}:
{
  addUserToApiGroup ? true,
  apiGroup ? null,
  forceMediaUMask ? false,
  name,
}:
let
  cfg = config.services.${name};
  hostCfg = config.host.${name};
  hostname = config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  service = hostInventory.servicesById.${name};
  instance = service.instances.${hostname} or { };
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaGroup = mediaExport.sharedGroup.name;
  isMediaServer = mediaExport.server == hostname;
  commonSettings = {
    auth = {
      method = "External";
      required = "Enabled";
    };
    log.analyticsEnabled = false;
    server.bindaddress = "127.0.0.1";
    update = {
      automatically = false;
      mechanism = "external";
    };
  };
in
{
  options = {
    host.${name}.enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname service;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns ${service.title} to this host.";
    };

    services.${name}.mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/${name}-media";
      description = "Local mount point for shared media storage.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = instance ? dataDir && instance ? mediaDir;
          message = "The ${service.title} inventory instance must define dataDir and mediaDir.";
        }
        {
          assertion = builtins.elem hostname mediaExport.clients;
          message = "The ${service.title} host must be an authorized media NFS client.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The ${service.title} host must be a declared backup client.";
        }
      ];

      services.${name} = {
        enable = true;
        dataDir = instance.dataDir;
        mediaDir = instance.mediaDir;
        user = name;
        group = mediaGroup;
        settings = commonSettings;
      };

      host.nfs.mounts = lib.mkIf (!isMediaServer) {
        media = instance.mediaDir;
      };

      users = {
        groups = lib.optionalAttrs (apiGroup != null) {
          ${apiGroup} = { };
        };
        users.${name} = {
          isSystemUser = true;
        }
        // lib.optionalAttrs (apiGroup != null && addUserToApiGroup) {
          extraGroups = [ apiGroup ];
        };
      };

      systemd.services.${name} = {
        unitConfig.RequiresMountsFor = instance.mediaDir;
        serviceConfig = lib.optionalAttrs forceMediaUMask {
          UMask = lib.mkForce "0002";
        };
      };

      host.internalService.services.${name} = {
        enable = true;
        upstream = "http://127.0.0.1:${toString cfg.settings.server.port}";
      };

      host.backups.jobs.${backupJob} = {
        paths = [ instance.dataDir ];
        exclude = [
          "${instance.dataDir}/logs"
          "${instance.dataDir}/logs/**"
          "${instance.dataDir}/cache"
          "${instance.dataDir}/cache/**"
        ];
      };
    })
  ];
}
