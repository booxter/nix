{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  services.fwupd.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

}
