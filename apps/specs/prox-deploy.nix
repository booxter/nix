{
  fleetInventory,
  inputs,
  pkgs,
  system,
  ...
}:
{
  package =
    (import ../proxmox.nix {
      inherit
        fleetInventory
        inputs
        pkgs
        system
        ;
    }).packages.prox-deploy;
  description = "Deploy a prox VM via nixmoxer.";
}
