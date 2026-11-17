{
  config,
  lib,
  pkgs,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  # Remove after the torrent subvolume mounts are merged into master.
  host.maintenance.holds.torrentMigration = "${pkgs.coreutils}/bin/false";

  host.network.interfaces.ens18 = { };

  host.qos.cakeIdleDecay.enable = true;

  host.observability.tracing.enable = true;

  host.proxmox.guest = {
    cores = 16;
    memoryGiB = 32;
  };

  host.backups.destination = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };

  host.storage.claims.media = {
    provider = "beast";
    resource = "media";
    mountPoint = "/data/media";
  };

  host.storage.claims.torrents = {
    provider = "beast";
    mountPoint = "/data/media/torrents";
    attachments = {
      transmission = { };
      sonarr = { };
      radarr = { };
      lidarr = { };
      shelfmark = { };
    };
  };

  # Arr stack
  host.bazarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/bazarr";
  };

  host.houndarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/houndarr";
    instances = {
      lidarr.api = "lidarr";
      radarr.api = "radarr";
      sonarr.api = "sonarr";
    };
  };

  # TODO: Investigate why Lidarr's live copyUsingHardlinks setting is disabled.
  host.lidarr = {
    stateDir = "/data/.state/nixarr/lidarr";
  };

  host.prowlarr = {
    stateDir = "/data/.state/nixarr/prowlarr";
  };

  services.flaresolverr = {
    enable = true;
    port = 8191;
  };

  systemd.services.flaresolverr.environment = {
    HOST = "127.0.0.1";
    LOG_LEVEL = "warning";
    TZ = config.host.site.timeZone;
  };

  host.radarr = {
    stateDir = "/data/.state/nixarr/radarr";
  };

  host.seerr = {
    stateDir = "/data/.state/nixarr/seerr";
    # TODO(seerr): revisit declarative settings reconciliation through Seerr's
    # public API once it has a reliable bootstrap/readiness contract. Do not
    # write its private database or inject Jellyfin API keys out of band.
  };

  host.sonarr = {
    stateDir = "/data/.state/nixarr/sonarr";
  };

  imports = [
    ./accounts.nix
    ./adaptive-upload-policy.nix
    ./audiobookshelf.nix
    ./aurral.nix
    ./glance.nix
    ./letterboxd.nix
    ./observability.nix
    ./pinepods.nix
    ./media-repair.nix
    ./romm.nix
    ./sabnzbd.nix
    ./shelfmark
    ./transmission.nix
    ./vpn.nix
  ];
}
