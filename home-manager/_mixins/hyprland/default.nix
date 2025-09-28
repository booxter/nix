{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  super = "MOD1";
in
{
  wayland.windowManager.hyprland = {
    enable = isLinux;
    xwayland.enable = true;
    systemd.enable = true;
    settings = {
      general = {
        gaps_in = 5;
        gaps_out = 2;
        "col.active_border" = "0xffFF0000";
      };
      ecosystem = {
        no_update_news = true;
      };

      animation = [
        "windows, 0"
      ];

      monitor = [
        "DP-2, 3840x2160@60, 0x0, 1.5"
        "HDMI-A-1, 1920x1080@60, 1920x0, 1"
      ];

      bind = [
        "${super}, H, movefocus, l"
        "${super}, J, movefocus, d"
        "${super}, K, movefocus, u"
        "${super}, L, movefocus, r"
        "${super}_SHIFT, H, swapwindow, l"
        "${super}_SHIFT, J, swapwindow, d"
        "${super}_SHIFT, K, swapwindow, u"
        "${super}_SHIFT, L, swapwindow, r"

        "${super}_SHIFT, Right, resizeactive, 50 0"
        "${super}_SHIFT, Left, resizeactive, -50 0"
        "${super}_SHIFT, Up, resizeactive, 0 -50"
        "${super}_SHIFT, Down, resizeactive, 0 50"

        "${super}, TAB, workspace, previous"

        "${super}_SHIFT, F, fullscreen, toggle"

        # TODO: parametrize the number of workspaces
        "${super}, 1, workspace, 1"
        "${super}, 2, workspace, 2"
        "${super}, 3, workspace, 3"
        "${super}, 4, workspace, 4"
        "${super}, 5, workspace, 5"
        "${super}, 6, workspace, 6"

        "${super}_SHIFT, 1, movetoworkspacesilent, 1"
        "${super}_SHIFT, 2, movetoworkspacesilent, 2"
        "${super}_SHIFT, 3, movetoworkspacesilent, 3"
        "${super}_SHIFT, 4, movetoworkspacesilent, 4"
        "${super}_SHIFT, 5, movetoworkspacesilent, 5"
        "${super}_SHIFT, 6, movetoworkspacesilent, 6"

        "${super}, Return, exec, ${lib.getExe pkgs.kitty}"
        "${super}, grave, exec, ${pkgs.kitty}/bin/kitten quick-access-terminal"
        "${super}, SPACE, exec, ${lib.getExe pkgs.wofi} --show drun"
      ];
    };
  };
}
