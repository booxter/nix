{ inputs, ... }:
{
  imports = [
    ./api-certificate.nix
    ./assertions.nix
    ./controller.nix
    ./guest.nix
    ./node.nix
    ./oidc.nix
    ./options.nix
    ./prometheus-exporter.nix
    inputs.proxmox-nixos.nixosModules.declarative-vms
    inputs.proxmox-nixos.nixosModules.proxmox-ve
  ];
}
