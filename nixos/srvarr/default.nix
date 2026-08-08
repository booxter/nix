{
  pkgs,
  ...
}:
{
  _module.args.srvarrPkgs = import ./pkgs pkgs;

  environment.systemPackages = [ pkgs.join-media-parts ];

  imports = [
    ./arr.nix
    ./aurral.nix
    ./backup.nix
    ./ebook-converter.nix
    ./glance.nix
    ./houndarr.nix
    ./letterboxd-list-radarr.nix
    ./lidarr-cue-splitter.nix
    ./nfs.nix
    ./oauth2-proxy.nix
    ./paths.nix
    ./pinepods.nix
    ./qos.nix
    ./romm.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark.nix
    ./slskd.nix
    ./transmission.nix
    ./tuning.nix
  ];
}
