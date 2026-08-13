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

  _module.args.srvarrPkgs = import ./pkgs pkgs;

  imports = [
    ./arr.nix
    ./audiobookshelf.nix
    ./aurral.nix
    ./glance.nix
    ./houndarr.nix
    ./letterboxd-list-radarr.nix
    ./lidarr-cue-splitter.nix
    ./media.nix
    ./oauth2-proxy.nix
    ./pinepods.nix
    ./romm.nix
    ./qos.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark
    ./storage.nix
    ./tuning.nix
    ./transmission.nix
    ./vpn.nix
  ];
}
