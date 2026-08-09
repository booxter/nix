{
  facts,
  inputs,
  pkgs,
  system,
  ...
}:
{
  package =
    (import ../proxmox.nix {
      inherit
        facts
        inputs
        pkgs
        system
        ;
    }).packages.prox-deploy;
  description = "Deploy a prox VM via nixmoxer.";
}
