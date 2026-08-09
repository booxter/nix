{ lib, ... }:
{
  imports = [ ./hyprland.nix ];

  options.host.desktop.hyprland.enable = lib.mkEnableOption "Hyprland desktop";
}
