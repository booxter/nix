{ inputs, ... }:
{
  imports = [
    ./api-certificate.nix
    ./assertions.nix
    ./guest.nix
    ./node.nix
    ./oidc.nix
    ./options.nix
    ./prometheus-exporter.nix
    inputs.proxmox-nixos.nixosModules.proxmox-ve
  ];
}
