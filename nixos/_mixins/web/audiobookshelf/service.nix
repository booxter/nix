{
  config,
  hostInventory,
  lib,
  utils,
  ...
}:
let
  cfg = config.services.audiobookshelf;
  hostCfg = config.host.audiobookshelf;
  hostname = config.networking.hostName;
  service = hostInventory.servicesById.audiobookshelf;
  instance = service.instances.${hostname} or { };
  account = hostInventory.serviceAccounts.audiobookshelf;
  mediaExport = hostInventory.storage.nfs.exports.media;
  isMediaServer = mediaExport.server == hostname;
  absoluteDataDir = lib.hasPrefix "/" cfg.dataDir;
  stateDir = if absoluteDataDir then cfg.dataDir else "/var/lib/${cfg.dataDir}";
  startCommand = utils.escapeSystemdExecArgs [
    (lib.getExe cfg.package)
    "--host"
    cfg.host
    "--port"
    (toString cfg.port)
    "--config"
    cfg.configDir
    "--metadata"
    cfg.metadataDir
  ];
in
{
  options = {
    host.audiobookshelf.enable = lib.mkOption {
      type = lib.types.bool;
      default = service.owner == hostname;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns Audiobookshelf to this host.";
    };

    services.audiobookshelf = {
      stateDir = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "Absolute root containing Audiobookshelf state.";
      };

      configDir = lib.mkOption {
        type = lib.types.str;
        default = "${stateDir}/config";
        description = "Directory containing the Audiobookshelf database and migrations.";
      };

      metadataDir = lib.mkOption {
        type = lib.types.str;
        default = "${stateDir}/metadata";
        description = "Directory containing Audiobookshelf metadata and native backups.";
      };

      localUrl = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "Loopback URL for the Audiobookshelf API.";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.hasAttr service.owner hostInventory.nixosHosts;
          message = "Audiobookshelf owner '${service.owner}' must be a managed NixOS host";
        }
        {
          assertion = !hostCfg.enable || hostInventory.nixosHosts.${service.owner}.realm == config.host.realm;
          message = "Audiobookshelf owner '${service.owner}' must belong to realm '${config.host.realm}'";
        }
      ];

      services.audiobookshelf = {
        inherit stateDir;
        localUrl = "http://${cfg.host}:${toString cfg.port}";
      };
    }

    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = instance ? dataDir && instance ? mediaDir;
          message = "The Audiobookshelf inventory instance must define dataDir and mediaDir.";
        }
        {
          assertion = builtins.elem hostname mediaExport.clients;
          message = "The Audiobookshelf owner must be an authorized media NFS client.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Audiobookshelf owner must be a declared backup client.";
        }
      ];

      services.audiobookshelf = {
        enable = true;
        dataDir = instance.dataDir;
        group = mediaExport.sharedGroup.name;
        port = 9292;
        user = "audiobookshelf";
        nativeBackup = {
          enable = true;
          backupJob = config.host.backups.destinationJob;
        };
        oidc.enable = true;
      };

      host.nfs.mounts = lib.mkIf (!isMediaServer) {
        media = instance.mediaDir;
      };

      users.users.${cfg.user} = {
        home = lib.mkForce "/var/empty";
        uid = account.uid;
      };

      systemd.tmpfiles.rules = lib.optional absoluteDataDir (
        "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
      );

      systemd.services.audiobookshelf = {
        unitConfig = {
          Wants = [ "network-online.target" ];
          After = [ "network-online.target" ];
          RequiresMountsFor = [
            cfg.stateDir
            instance.mediaDir
          ];
        };
        serviceConfig = {
          ExecStart = lib.mkForce startCommand;
          WorkingDirectory = lib.mkForce cfg.stateDir;
        }
        // lib.optionalAttrs absoluteDataDir {
          StateDirectory = lib.mkForce null;
        };
      };

      services.nginx.commonHttpConfig = ''
        map $http_x_forwarded_host $audiobookshelf_proxy_host {
            default $http_x_forwarded_host;
            "" $host;
        }

        map $http_x_forwarded_proto $audiobookshelf_proxy_proto {
            default $http_x_forwarded_proto;
            "" $scheme;
        }
      '';

      host.internalService.services.audiobookshelf = {
        enable = true;
        upstream = cfg.localUrl;
        publicAliases = [ service.publicHost ];
        mtls.enable = true;
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host $audiobookshelf_proxy_host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $audiobookshelf_proxy_proto;
          proxy_set_header X-Forwarded-Host $audiobookshelf_proxy_host;
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };
    })
  ];
}
