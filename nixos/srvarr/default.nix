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

  host.aurral = {
    enable = true;
    stateDir = "${config.host.srvarrPaths.stateDir}/aurral";
    flowDir = "${config.host.srvarrPaths.mediaDir}/library/flows";
    extraWritePaths = [ "${config.host.srvarrPaths.mediaDir}/slskd/complete" ];
    extraGroups = [ "media" ];
    publicHostName = "mu.${config.host.network.publicDomain}";
    authProxy.adminGroups = [ "media-admins" ];
  };

  imports = [
    ./arr.nix
    ./audiobookshelf.nix
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
