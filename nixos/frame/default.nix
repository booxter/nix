{ inputs, ... }:
{
  imports = [
    (import ../../disko/luks.nix { })
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
    ./ups.nix
  ];

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
