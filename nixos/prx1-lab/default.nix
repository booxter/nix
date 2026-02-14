{ lib, ... }:
{
  imports = [
    (import ../../disko { })
    ./ups.nix
  ];

  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

}
