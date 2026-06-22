{
  inputs,
  pkgs,
  ...
}:
{
  _module.args.srvarrPkgs = import ./pkgs pkgs;

  imports = [
    inputs.vpnconfinement.nixosModules.default
    ./arr.nix
    ./audiobookshelf.nix
    ./aurral.nix
    ./backup.nix
    ./glance.nix
    ./nfs.nix
    ./paths.nix
    ./romm.nix
    ./qos.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark.nix
    ./tuning.nix
    ./transmission.nix
    ./vpn.nix
  ];
}
