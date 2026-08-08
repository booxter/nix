{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.jellyfin;
  hostname = config.networking.hostName;
  jellyfinService = hostInventory.servicesById.jellyfin;
  watchstateService = hostInventory.servicesById.watchstate;
  mediaExport = hostInventory.storage.nfs.exports.media;
  isMediaServer = mediaExport.server == hostname;
  realmPublicIngress = hostInventory.realms.${config.host.realm}.services.publicIngress or null;
  ownerExists = builtins.hasAttr jellyfinService.owner hostInventory.nixosHosts;
  dataMount = config.host.storage.volumes.data.mounts.data.mountPoint;
  backupStagingDir =
    if config.host.backups.client.isLocal then
      "${dataMount}/backups/staging/jellyfin"
    else
      "/var/lib/jellyfin-backups";
  backupGroup =
    if config.host.backups.client.isLocal then config.host.backups.server.cloud.group else "root";
in
{
  options.host.jellyfin.enable = lib.mkOption {
    type = lib.types.bool;
    default = jellyfinService.owner == hostname;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns the Jellyfin service to this host.";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = ownerExists;
          message = "Jellyfin owner '${jellyfinService.owner}' must be a managed NixOS host";
        }
        {
          assertion =
            !cfg.enable || hostInventory.nixosHosts.${jellyfinService.owner}.realm == config.host.realm;
          message = "Jellyfin owner '${jellyfinService.owner}' must belong to realm '${config.host.realm}'";
        }
      ];

      services.jellyfin.enable = cfg.enable;
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.host.gpu != null && config.host.gpu.videoAcceleration != null;
          message = "The Jellyfin owner must provide hardware video acceleration.";
        }
        {
          assertion = watchstateService.owner == hostname;
          message = "Jellyfin currently requires WatchState on the same host.";
        }
        {
          assertion = realmPublicIngress != null && realmPublicIngress.host == hostname;
          message = "Jellyfin currently requires the realm's public ingress on the same host.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Jellyfin owner must be a declared backup client.";
        }
      ];

      services.jellyfin = {
        builtInBackup = {
          enable = true;
          backupJob = config.host.backups.destinationJob;
          group = backupGroup;
          stagingDir = backupStagingDir;
        };
        downloadLimiter = {
          enable = true;
          publicHost = jellyfinService.publicHost;
          unlimitedNetworks = [
            "127.0.0.0/8"
            "::1"
            hostInventory.site.lan.cidr
            "fe80::/10"
            "fc00::/7"
          ];
        };
        exporter.enable = true;
        logging.playbackDebug = true;
        maintenance = {
          enable = true;
          units = [
            "nixos-upgrade"
            "nixos-weekly-reboot-if-needed"
          ];
        };
        mediaMount = {
          enable = isMediaServer;
        }
        // lib.optionalAttrs isMediaServer {
          source = mediaExport.path;
          sourceMount = dataMount;
        };
        meilisearch.enable = true;
        supplementaryGroups = [ mediaExport.sharedGroup.name ];
        useHostVideoAcceleration = true;
      };

      host.nfs.mounts = lib.mkIf (!isMediaServer) {
        media = config.services.jellyfin.mediaMount.target;
      };

      systemd.services.jellyfin.unitConfig.RequiresMountsFor = lib.mkIf (
        !isMediaServer
      ) config.services.jellyfin.mediaMount.target;

      host.publicIngress.exports.jellyfin = {
        inherit (jellyfinService) publicHost;
        backend = {
          type = "local-http";
          url = config.services.jellyfin.localUrl;
        };
      };
    })
  ];
}
