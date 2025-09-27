{ lib, pkgs, ... }: let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
in {
  wayland.windowManager.hyprland = lib.mkIf isLinux {
    enable = true;
    xwayland.enable = true;
    systemd.enable = true;
    settings = {
      ecosystem = {
        no_update_news = true;
      };
    };
  };
}
