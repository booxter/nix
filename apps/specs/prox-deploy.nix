{
  inputs,
  outputs,
  pkgs,
  system,
  ...
}:
{
  package =
    (import ../proxmox.nix {
      inherit
        inputs
        outputs
        pkgs
        system
        ;
    }).packages.prox-deploy;
  description = "Deploy a prox VM via nixmoxer.";
}
