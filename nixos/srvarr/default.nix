{ lib, pkgs, ... }:
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

  host.media.libraries = {
    books = {
      contentType = "ebooks";
      storage = {
        claim = "media";
        relativePath = "library/books";
      };
    };
    audiobooks = {
      contentType = "audiobooks";
      storage = {
        claim = "media";
        relativePath = "library/audiobooks";
      };
    };
  };

  _module.args.srvarrPkgs = import ./pkgs pkgs;

  imports = [
    ./arr.nix
    ./audiobookshelf.nix
    ./aurral.nix
    ./glance.nix
    ./houndarr.nix
    ./letterboxd-list-radarr.nix
    ./lidarr-cue-splitter.nix
    ./oauth2-proxy.nix
    ./pinepods.nix
    ./romm.nix
    ./qos.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark
    ./tuning.nix
    ./transmission.nix
    ./vpn.nix
  ];
}
