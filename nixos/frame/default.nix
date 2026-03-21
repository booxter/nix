{ inputs, lib, ... }:
{
  imports = [
    (import ../../disko/luks.nix { })
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./ups.nix
  ];

  # This host needs manual unlock after boot; never auto-reboot on upgrades.
  system.autoUpgrade.allowReboot = lib.mkForce false;

  networking.wireless.enable = false;
  networking.wireless.secretsFile = "/etc/wireless.secrets";
  networking.wireless.networks = {
    booxter = {
      pskRaw = "ext:psk_booxter";
    };
  };

  services.displayManager.gdm = {
    enable = true;
    wayland = true;
  };
  programs.hyprland.enable = true;
}
