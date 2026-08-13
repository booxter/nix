{ lib, ... }:
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
      enable = true;
      address = "192.168.20.2";
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

  imports = [
    ./adaptive-upload-policy.nix
    ./bazarr.nix
    ./audiobookshelf.nix
    ./aurral.nix
    ./glance.nix
    ./houndarr.nix
    ./lidarr.nix
    ./pinepods.nix
    ./prowlarr.nix
    ./radarr.nix
    ./romm.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark
    ./transmission.nix
    ./sonarr.nix
    ./vpn.nix
  ];
}
