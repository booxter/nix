{
  lib,
  pkgs,
  username,
  ...
}:
{
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  environment.systemPackages = with pkgs; [
    kitty
    podman-desktop
  ];

  virtualisation.vmVariant.virtualisation = {
    graphics = lib.mkForce true;
  };

  users.users.${username} = {
    password = "testpass";
  };
}
