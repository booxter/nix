{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  systemd.timers.nixos-auto-upgrade.timerConfig.OnCalendar = lib.mkForce "Sun 03:00";
}
