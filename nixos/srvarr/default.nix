{
  pkgs,
  ...
}:
{
  _module.args.srvarrPkgs = import ./pkgs pkgs;

  environment.systemPackages = [ pkgs.join-media-parts ];

  imports = [
    ./aurral.nix
    ./backup.nix
    ./glance.nix
    ./nfs.nix
    ./oauth2-proxy.nix
    ./paths.nix
    ./qos.nix
    ./sabnzbd.nix
    ./slskd.nix
    ./transmission.nix
    ./tuning.nix
  ];
}
