{ inputs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./btrfs
    ./disko
    ./md-raid.nix
    ./media-layout.nix
    ./nfs
    ./observability
    ./smart.nix
    ./volumes.nix
  ];

  # VM variants use synthetic filesystems rather than the host's physical storage.
  virtualisation.vmVariant.host.storage.useInventory = false;
}
