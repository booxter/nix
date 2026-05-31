{ ... }:
{
  imports = [
    (import ../../disko { })
    ./netboot.nix
    ./ups.nix
  ];
}
