{ lib, ... }:
{
  imports = [ ./displays.nix ];

  options.host.hardware.isLaptop = lib.mkEnableOption "laptop hardware";
}
