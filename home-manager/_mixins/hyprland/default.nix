# TODO: refactor the module
{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux;
  super = "MOD1";
  cmdButton = "MOD4";
in
{
  home.packages = lib.mkIf isLinux (
    with pkgs;
    [
      wev
      wl-clipboard
      wlrctl
      wtype
    ]
  );

  services.hypridle = {
    enable = isLinux;
    settings =
      let
        hyprctl = "${pkgs.hyprland}/bin/hyprctl";
      in
      {
        general = {
          ignore_dbus_inhibit = false;
        };

        listener = [
          {
            timeout = 120;
            on-timeout = "${hyprctl} dispatch dpms off";
            on-resume = "${hyprctl} dispatch dpms on";
          }
        ];
      };
  };

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

  home.sessionVariables = {
    GTK_THEME = "palenight";

    # https://wiki.hypr.land/Configuring/XWayland/
    GDK_SCALE = 2;
    XCURSOR_SIZE = 32;
  };

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
          on-click = "activate";
          disable-scroll = true;
          all-outputs = true;
          show-special = true;
          active-only = false;
          format = "{name}:{icon}";
          format-icons = {
            "1" = "";
            "2" = "";
            "3" = "";
            "4" = "";
            "5" = "";
            "6" = "";
            active = "";
            default = "";
            empty = "";
            visible = "";
          };
          persistent-workspaces = {
            "*" = [
              "1"
              "2"
              "3"
              "4"
            ];
            # right
            "DP-2" = [
              "5"
              "6"
            ];
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

      animations = {
        enabled = 0;
      };

      monitor = [
        "DP-4, 3840x2160@60, 0x0, 1.5" # left
        "DP-2, 3840x2160@60, 2560x0, 1.5" # right (logical width = 3840/1.5)
      ];

      xwayland = {
        # https://wiki.hypr.land/Configuring/XWayland/
        force_zero_scaling = true;
      };

      workspace = [
        # left
        "1, monitor:DP-4"
        "2, monitor:DP-4"
        "3, monitor:DP-4"
        "4, monitor:DP-4"
        # right
        "5, monitor:DP-2"
        "6, monitor:DP-2"
      ];

      input =
        let
          natural_scroll = true;
        in
        {
          inherit natural_scroll;
          kb_layout = "us";

          repeat_delay = 210;
          repeat_rate = 33;

          touchpad = {
            inherit natural_scroll;
            disable_while_typing = true;
            tap-to-click = true;
          };
        };

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

        "${super}, Q, killactive"
        "${super}_SHIFT, Q, exit"

        "${super}, Return, exec, ${lib.getExe pkgs.kitty}"
        "${super}, grave, exec, ${pkgs.kitty}/bin/kitten quick-access-terminal"
        "${super}, SPACE, exec, ${lib.getExe pkgs.wofi} --show drun"

        "${cmdButton}, C, exec, ${pkgs.wl-clipboard}/bin/wl-paste --primary | ${pkgs.wl-clipboard}/bin/wl-copy --trim-newline"

        "${cmdButton}, V, sendshortcut, CTRL, v, class:^([^k]|k($|[^i]|i($|[^t]|t($|[^t]|t($|[^y])))))*$" # holly shit... re2 doesn't support negatives like (?!...)
        "${cmdButton}, V, sendshortcut, CTRL SHIFT, v, class:^kitty$"

      ];
    };
  };
}
