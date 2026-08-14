{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf config.host.desktop.enable {
    services.displayManager = {
      gdm.enable = true;
      defaultSession = "hyprland";
    };
    programs.hyprland.enable = true;
    security.pam.services.hyprlock = { };
  };
}
