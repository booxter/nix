{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  services.fwupd.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Intel CPU microcode updates
  hardware.cpu.intel.updateMicrocode = true;

  systemd.timers.nixos-auto-upgrade.timerConfig.OnCalendar = lib.mkForce "Sun 03:00";
}
