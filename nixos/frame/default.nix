{ inputs, ... }:
{
  imports = [
    (import ../../disko/luks.nix { })
    inputs.nixos-hardware.nixosModules.framework-desktop-amd-ai-max-300-series
  ];

  services.fwupd.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Attempt to fix DNS resolution: https://github.com/tailscale/tailscale/issues/4254
  # TODO: consider for other nixos machines
  services.resolved.enable = true;

  networking.wireless.enable = true;
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
