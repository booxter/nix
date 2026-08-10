{ lib, ... }:
{
  imports = [
    ./displays.nix
    ./storage.nix
  ];

  options.host.hardware.isLaptop = lib.mkEnableOption "laptop hardware";
}
