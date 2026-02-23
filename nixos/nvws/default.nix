{ lib, ... }:
{
  imports = [
    (import ../../disko { })
  ];

  # Allow local builds for aarch64-linux on this x86_64 host via qemu/binfmt.
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  nix.settings.extra-platforms = [ "aarch64-linux" ];

}
