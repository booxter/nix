{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  services.fwupd.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

  system.autoUpgrade.dates = lib.mkForce "Sun 03:00";
}
