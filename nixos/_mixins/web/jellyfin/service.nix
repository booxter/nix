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
  mediaExport = hostInventory.storage.nfs.exports.media;
  isMediaServer = mediaExport.server == hostname;
  realmPublicIngress = hostInventory.realms.${config.host.realm}.services.publicIngress or null;
  backupStagingDir = "${config.host.backups.staging.root}/jellyfin";
in
{
  options.host.jellyfin.enable = lib.mkOption {
    type = lib.types.bool;
    default = hostInventory.serviceRunsOn hostname jellyfinService;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns the Jellyfin service to this host.";
  };

  config = lib.mkMerge [
    {
      services.jellyfin.enable = cfg.enable;
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.host.gpu != null && config.host.gpu.videoAcceleration != null;
          message = "The Jellyfin host must provide hardware video acceleration.";
        }
        {
          assertion = realmPublicIngress != null && realmPublicIngress.host == hostname;
          message = "Jellyfin currently requires the realm's public ingress on the same host.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Jellyfin host must be a declared backup client.";
        }
      ];

      services.jellyfin = {
        builtInBackup = {
          enable = true;
          backupJob = config.host.backups.destinationJob;
          group = config.host.backups.staging.group;
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
          sourceMount = mediaExport.backingMount;
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
