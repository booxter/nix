{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  super = "MOD1";
in
{
  home.packages = lib.mkIf isLinux (with pkgs; [
    wl-clipboard
  ]);

  # TODO: rename module?
  gtk = {
    enable = isLinux;

    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };

    theme = {
      name = "palenight";
      package = pkgs.palenight-theme;
    };

    cursorTheme = {
      name = "Numix-Cursor";
      package = pkgs.numix-cursor-theme;
    };

    gtk3.extraConfig = {
      Settings = ''
        gtk-application-prefer-dark-theme=1
      '';
    };

    gtk4.extraConfig = {
      Settings = ''
        gtk-application-prefer-dark-theme=1
      '';
    };
  };

  home.sessionVariables.GTK_THEME = "palenight";

  programs.waybar = {
    enable = isLinux;
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = 25;
        modules-left = [ "hyprland/workspaces" ];
        modules-right = [ "clock" ];
        "hyprland/workspaces" = {
          format = "{name} : {icon}";
          on-click = "activate";
          disable-scroll = true;
          all-outputs = true;
          sort-by-number = true;
          format-icons = {
            "1" = "";
            "2" = "";
            "3" = "";
            "4" = "";
            "5" = "";
            active = "";
            default = "";
          };
        };
        clock = {
          format = "{:%H:%M}";
        };
      };
    };
  };

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

      exec-once = [
        "waybar"
      ];

      ecosystem = {
        no_update_news = true;
      };

      animation = [
        "windows, 0"
      ];

      monitor = [
        "DP-2, 3840x2160@60, 0x0, 1.5"

        # use lower res to accommodate junky kvm hdmi flickering
        "HDMI-A-1, 1920x1080@60, auto-right, 1"
      ];

      workspace = [
        "1, monitor:DP-2"
        "2, monitor:DP-2"
        "3, monitor:DP-2"
        "4, monitor:DP-2"
        "5, monitor:HDMI-A-1"
        "6, monitor:HDMI-A-1"
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
