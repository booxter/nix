{
  inputs,
  ...
}:
{
  imports = [
    inputs.vpnconfinement.nixosModules.default
    ./arr.nix
    ./audiobookshelf.nix
    ./contract.nix
    ./aurral.nix
    ./backup.nix
    ./glance.nix
    ./nfs.nix
    ./paths.nix
    ./qos.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark.nix
    ./tuning.nix
    ./transmission.nix
    ./vpn.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;
}
