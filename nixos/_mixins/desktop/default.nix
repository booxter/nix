{ lib, ... }:
{
  imports = [ ./hyprland.nix ];

  options.host.desktop.enable = lib.mkEnableOption "graphical desktop";
}
