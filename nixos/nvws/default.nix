{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  security.sudo.wheelNeedsPassword = lib.mkForce true;
}
