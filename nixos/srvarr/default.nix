{ pkgs, ... }:
{
  system.stateVersion = "25.11";

  host.proxmox.guest.cluster = "lab";
  host.network = {
    macAddress = "bc:24:11:19:4d:d1";
    reservation = {
      enable = true;
      address = "192.168.20.2";
    };
  };

  _module.args.srvarrPkgs = import ./pkgs pkgs;

  imports = [
    ./arr.nix
    ./audiobookshelf.nix
    ./aurral.nix
    ./ebook-converter.nix
    ./glance.nix
    ./houndarr.nix
    ./letterboxd-list-radarr.nix
    ./lidarr-cue-splitter.nix
    ./nfs.nix
    ./oauth2-proxy.nix
    ./paths.nix
    ./pinepods.nix
    ./romm.nix
    ./qos.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark.nix
    ./slskd.nix
    ./tuning.nix
    ./transmission.nix
    ./vpn.nix
  ];
}
