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
      services.displayManager = {
        defaultSession = "hyprland";
        gdm.enable = true;
      };
      programs.hyprland.enable = true;
    })
  ];
}
