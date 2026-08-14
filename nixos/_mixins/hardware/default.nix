{ pkgs, ... }:
{
  imports = [
    ./disk-bays.nix
    ./firmware.nix
    ./gpu
    ./hba.nix
    ./mdraid.nix
    ./smart.nix
    ./storage.nix
  ];

  environment.systemPackages = with pkgs; [
    pciutils
    usbutils
  ];
}
