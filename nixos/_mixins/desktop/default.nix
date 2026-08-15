{
  config,
  lib,
  ...
}:
{
  config = lib.mkIf (config.host.desktop != null) {
    services.displayManager = {
      gdm.enable = true;
      defaultSession = "hyprland";
    };
    services.xserver = {
      autoRepeatDelay = 210; # ms before repeat starts (macOS InitialKeyRepeat=14)
      autoRepeatInterval = 30; # ms between repeats (macOS KeyRepeat=1)
    };
    programs.hyprland.enable = true;
    security.pam.services.hyprlock = { };
  };
}
