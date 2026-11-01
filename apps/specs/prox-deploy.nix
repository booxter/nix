{
  fleetInventory,
  inputs,
  pkgs,
  ...
}:
{
  package =
    (import ../proxmox.nix {
      inherit
        fleetInventory
        inputs
        pkgs
        ;
    }).packages.prox-deploy;
  description = "Deploy a prox VM via nixmoxer.";
}
