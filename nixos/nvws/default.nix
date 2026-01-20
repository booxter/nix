{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  system.autoUpgrade.dates = lib.mkForce "Sun 03:00";
}
