{
  config,
  lib,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.network = {
    interfaces.ens18.kind = "ethernet";
    macAddress = "bc:24:11:19:4d:d1";
    primaryInterface = "ens18";
    reservation = {
      address = "192.168.20.2";
    };
  };

  host.proxmox = {
    cluster = "lab";
    guest = {
      enable = true;
      cores = 16;
      memoryGiB = 32;
    };
  };

  host.ups.client.server = "prx1-lab";

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };

  host.storage.claims.media = {
    provider = "beast";
    resource = "media";
    mountPoint = "/data/media";
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

  host.lidarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/lidarr";
    cueSplitter.enable = true;
  };

  host.prowlarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/prowlarr";
  };

  host.radarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/radarr";
    letterboxdList.enable = true;
  };

  host.seerr = {
    enable = true;
    stateDir = "/data/.state/nixarr/seerr";
    publicHostName = "js.${config.host.network.publicDomain}";
    # TODO(seerr): revisit declarative settings reconciliation through Seerr's
    # public API once it has a reliable bootstrap/readiness contract. Do not
    # write its private database or inject Jellyfin API keys out of band.
  };

  host.sonarr = {
    enable = true;
    stateDir = "/data/.state/nixarr/sonarr";
  };

  imports = [
    ./adaptive-upload-policy.nix
    ./audiobookshelf.nix
    ./aurral.nix
    ./glance.nix
    ./pinepods.nix
    ./romm.nix
    ./sabnzbd.nix
    ./shelfmark
    ./transmission.nix
    ./vpn.nix
  ];
}
