{
  inputs,
  ...
}:
let
  wgConservativeUploadRateMbit = 8;
  transmissionNonPreferredLowPriorityRatio = 3.0;
  transmissionNonPreferredPauseRatio = 6.0;
in
{
  _module.args = {
    inherit
      transmissionNonPreferredLowPriorityRatio
      transmissionNonPreferredPauseRatio
      wgConservativeUploadRateMbit
      ;
  };

  imports = [
    inputs.vpnconfinement.nixosModules.default
    ./arr.nix
    ./audiobookshelf.nix
    ./contract.nix
    ./aurral.nix
    ./backup.nix
    ./glance.nix
    ./nfs.nix
    ./qos.nix
    ./sabnzbd.nix
    ./seerr.nix
    ./shelfmark.nix
    ./transmission.nix
    ./vpn.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;
}
