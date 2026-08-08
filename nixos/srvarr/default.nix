{
  pkgs,
  ...
}:
{
  _module.args.srvarrPkgs = import ./pkgs pkgs;

  environment.systemPackages = [ pkgs.join-media-parts ];

  imports = [
    ./backup.nix
    ./nfs.nix
    ./oauth2-proxy.nix
    ./paths.nix
    ./qos.nix
    ./sabnzbd.nix
    ./transmission.nix
    ./tuning.nix
  ];
}
