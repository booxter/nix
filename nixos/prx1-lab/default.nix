{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

}
