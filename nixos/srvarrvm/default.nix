{
  config,
  hostInventory,
  inputs,
  ...
}:
let
  wgConservativeUploadRateMbit = 8;
  transmissionNonPreferredLowPriorityRatio = 3.0;
  transmissionNonPreferredPauseRatio = 6.0;
  jellyseerrService = hostInventory.servicesById.jellyseerr;
  aurralService = hostInventory.servicesById.aurral;
  audiobookshelfService = hostInventory.servicesById.audiobookshelf;
  shelfmarkService = hostInventory.servicesById.shelfmark;
in
{
  _module.args = {
    inherit
      transmissionNonPreferredLowPriorityRatio
      transmissionNonPreferredPauseRatio
      wgConservativeUploadRateMbit
      ;
  };

  imports = [
    inputs.vpnconfinement.nixosModules.default
    ./audiobookshelf.nix
    ./contract.nix
    ./aurral.nix
    ./backup.nix
    ./bazarr.nix
    ./glance.nix
    ./lidarr.nix
    ./nfs.nix
    ./prowlarr.nix
    ./qos.nix
    ./radarr.nix
    ./sabnzbd.nix
    ./sabnzbd-exporter.nix
    ./seerr.nix
    ./shelfmark.nix
    ./sonarr.nix
    ./transmission.nix
    ./transmission-torrent-cleaner.nix
    ./transmission-prioritizer.nix
    ./vpn.nix
    ./wg-bridge-access.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;

  host.internalHttps.services = {
    jellyseerr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
      serverAliases = [ jellyseerrService.publicHost ];
      mtls.enable = true;
    };
    aurral = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.host.srvarr.services.aurral.port}";
      serverAliases = [ aurralService.publicHost ];
      mtls.enable = true;
    };
    audiobookshelf = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.audiobookshelf.port}";
      serverAliases = [ audiobookshelfService.publicHost ];
      mtls.enable = true;
    };
    shelfmark = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.shelfmark.environment.FLASK_PORT}";
      serverAliases = [ shelfmarkService.publicHost ];
      mtls.enable = true;
    };
  };

}
