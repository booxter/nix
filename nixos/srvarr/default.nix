{
  lib,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.network.interfaces.ens18 = { };

  host.proxmox.guest = {
    cluster = "lab";
    cores = 16;
    memoryGiB = 32;
  };

  host.ups.client.server = "prx1-lab";

  host.backups.destination = {
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
    stateDir = "/data/.state/nixarr/lidarr";
  };

  host.prowlarr = {
    stateDir = "/data/.state/nixarr/prowlarr";
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
    ./pinepods.nix
    ./romm.nix
    ./sabnzbd.nix
    ./shelfmark
    ./transmission.nix
    ./vpn.nix
  ];
}
