# TODO: refactor the module
{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.hyprland;
  super = "MOD1";
  cmdButton = "MOD4";
  inherit (osConfig.host.hardware) displayMode displays scale;
  displaysByName = lib.listToAttrs (
    map (display: lib.nameValuePair display.position display) displays
  );
  inherit (displaysByName) left right;
  renderMonitor =
    display:
    "${display.connector}, ${toString displayMode.width}x${toString displayMode.height}@${toString displayMode.refreshRate}, ${toString display.x}x0, ${toString scale}";
  workspaceNames = map toString (lib.range 1 cfg.numberedWorkspaces);
  leftWorkspaceNames = map toString (lib.range 1 cfg.leftMonitorWorkspaces);
  rightWorkspaceNames =
    if cfg.leftMonitorWorkspaces < cfg.numberedWorkspaces then
      map toString (lib.range (cfg.leftMonitorWorkspaces + 1) cfg.numberedWorkspaces)
    else
      [ ];
  workspaceIcons =
    builtins.listToAttrs (map (workspace: lib.nameValuePair workspace "") workspaceNames)
    // {
      active = "";
      default = "";
      empty = "";
      visible = "";
    };
  persistentWorkspaces = {
    "*" = leftWorkspaceNames;
  }
  // lib.optionalAttrs (rightWorkspaceNames != [ ]) {
    "${right.connector}" = rightWorkspaceNames;
  };
  workspaceMonitorRules =
    map (workspace: "${workspace}, monitor:${left.connector}") leftWorkspaceNames
    ++ map (workspace: "${workspace}, monitor:${right.connector}") rightWorkspaceNames;
  workspaceBindings = lib.concatMap (workspace: [
    "${super}, ${workspace}, workspace, ${workspace}"
    "${super}_SHIFT, ${workspace}, movetoworkspacesilent, ${workspace}"
  ]) workspaceNames;
in
{
  options.host.hm.hyprland = {
    enable = lib.mkEnableOption "Hyprland desktop environment";

    numberedWorkspaces = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = config.host.hm.numberedWorkspaces;
      description = "Number of numbered Hyprland workspaces.";
    };

    leftMonitorWorkspaces = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = lib.min 4 cfg.numberedWorkspaces;
      description = "Number of leading workspaces assigned to the left monitor.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !osConfig.host.isDarwin;
        message = "host.hm.hyprland is only supported on Linux.";
      }
      {
        assertion = cfg.leftMonitorWorkspaces <= cfg.numberedWorkspaces;
        message = "host.hm.hyprland.leftMonitorWorkspaces cannot exceed numberedWorkspaces.";
      }
    ];

    home.packages = with pkgs; [
      wev
      wl-clipboard
      wlrctl
      wtype
    ];

    services.hypridle = {
      enable = true;
      settings =
        let
          hyprctl = "${pkgs.hyprland}/bin/hyprctl";
          hyprlock = "${pkgs.hyprlock}/bin/hyprlock";
          loginctl = "${pkgs.systemd}/bin/loginctl";
          pidof = "${pkgs.procps}/bin/pidof";
        in
        {
          general = {
            after_sleep_cmd = "${hyprctl} dispatch dpms on";
            before_sleep_cmd = "${loginctl} lock-session";
            ignore_dbus_inhibit = false;
            lock_cmd = "${pidof} hyprlock || ${hyprlock}";
          };

          listener = [
            {
              timeout = 120;
              on-timeout = "${loginctl} lock-session";
            }
            {
              timeout = 150;
              on-timeout = "${hyprctl} dispatch dpms off";
              on-resume = "${hyprctl} dispatch dpms on";
            }
          ];
        };
    };

    programs.hyprlock = {
      enable = true;
      settings = {
        general = {
          hide_cursor = true;
        };

        background = {
          monitor = "";
          path = "screenshot";
          blur_passes = 3;
          blur_size = 8;
        };

        input-field = {
          monitor = "";
          size = "240, 56";
          position = "0, -80";
          dots_center = true;
          fade_on_empty = false;
          outline_thickness = 2;
          placeholder_text = "YubiKey PIN or password...";
          shadow_passes = 2;
        };
      };
    };

    programs.waybar = {
      enable = true;
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
            format-icons = workspaceIcons;
            persistent-workspaces = persistentWorkspaces;
          };
          clock = {
            format = "{:%H:%M}";
          };
        };
      };
    };

    wayland.windowManager.hyprland = {
      enable = true;
      configType = "hyprlang";
      # NixOS owns portal packages/config for the desktop session. Keep Home
      # Manager from exposing a second per-user portal view while still letting it
      # manage Hyprland config and reload hooks.
      portalPackage = null;
      xwayland.enable = true;
      systemd.enable = true;
      settings = {
        general = {
          gaps_in = 5;
          gaps_out = 2;
        };

        exec-once = [
          "waybar"
        ];

        # Keep XWayland scaling local to the Hyprland session so SSH-forwarded
        # X11 apps do not inherit it under XQuartz.
        # https://wiki.hypr.land/Configuring/XWayland/
        env = [
          "GDK_SCALE,2"
          "XCURSOR_SIZE,64"
        ];

        ecosystem = {
          no_donation_nag = true;
          no_update_news = true;
        };

        animations = {
          enabled = 0;
        };

        windowrule = [
          "match:title ^OpenSSH authentication$, stay_focused on"
        ];

        monitor = map renderMonitor displays;

        xwayland = {
          # https://wiki.hypr.land/Configuring/XWayland/
          force_zero_scaling = true;
        };

        workspace = workspaceMonitorRules;

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

          "${super}, Q, killactive"
          "${super}_SHIFT, Q, exit"

          "${super}, Return, exec, ${lib.getExe pkgs.kitty}"
          "${super}, grave, exec, ${pkgs.kitty}/bin/kitten quick-access-terminal"
          "${super}, SPACE, exec, ${lib.getExe pkgs.wofi} --show drun"

          "${cmdButton}, C, exec, ${pkgs.wl-clipboard}/bin/wl-paste --primary | ${pkgs.wl-clipboard}/bin/wl-copy --trim-newline"

          "${cmdButton}, V, sendshortcut, CTRL, v, class:^([^k]|k($|[^i]|i($|[^t]|t($|[^t]|t($|[^y])))))*$" # holly shit... re2 doesn't support negatives like (?!...)
          "${cmdButton}, V, sendshortcut, CTRL SHIFT, v, class:^kitty$"

        ]
        ++ workspaceBindings;
      };
    };
  };
}
