{ config, lib, ... }:
let
  environment = config.host.desktop.environment;
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.host.isDesktop == (environment != null);
          message = "NixOS desktop hosts must select exactly one supported host.desktop.environment";
        }
      ];
    }
    (lib.mkIf (environment == "hyprland") {
      services = {
        displayManager = {
          defaultSession = "hyprland";
          gdm.enable = true;
        };
        xserver = {
          # Match the native Hyprland input policy for X11-side sessions.
          autoRepeatDelay = 210;
          autoRepeatInterval = 30;
        };
      };
      programs.hyprland.enable = true;
      security.pam.services.hyprlock = { };
    })
  ];
}
