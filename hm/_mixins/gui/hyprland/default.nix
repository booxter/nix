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
  super = "ALT";
  cmdButton = "SUPER";
  lua = lib.generators.mkLuaInline;
  toLua = lib.generators.toLua { };
  bind = key: dispatcher: {
    _args = [
      key
      (lua dispatcher)
    ];
  };
  exec = key: command: bind key "hl.dsp.exec_cmd(${toLua command})";
  inherit (osConfig.host.hardware) displayMode displays scale;
  displaysByName = lib.listToAttrs (
    map (display: lib.nameValuePair display.position display) displays
  );
  inherit (displaysByName) left right;
  renderMonitor = display: {
    output = display.connector;
    mode = "${toString displayMode.width}x${toString displayMode.height}@${toString displayMode.refreshRate}";
    position = "${toString display.x}x0";
    inherit scale;
  };
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
    map (workspace: {
      inherit workspace;
      monitor = left.connector;
    }) leftWorkspaceNames
    ++ map (workspace: {
      inherit workspace;
      monitor = right.connector;
    }) rightWorkspaceNames;
  workspaceBindings = lib.concatMap (workspace: [
    (bind "${super} + ${workspace}" "hl.dsp.focus({ workspace = ${toLua workspace} })")
    (bind "${super} + SHIFT + ${workspace}" "hl.dsp.window.move({ workspace = ${toLua workspace}, follow = false })")
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
        assertion = !osConfig.nixpkgs.hostPlatform.isDarwin;
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
          loginctl = "${pkgs.systemd}/bin/loginctl";
          systemctl = "${pkgs.systemd}/bin/systemctl";
        in
        {
          general = {
            after_sleep_cmd = "${hyprctl} dispatch \"hl.dsp.dpms({ action = 'enable' })\"";
            before_sleep_cmd = "${loginctl} lock-session";
            ignore_dbus_inhibit = false;
            lock_cmd = "${systemctl} --user start hyprlock.service";
          };

          listener = [
            {
              timeout = 300;
              on-timeout = "${loginctl} lock-session";
            }
            {
              timeout = 600;
              on-timeout = "${hyprctl} dispatch \"hl.dsp.dpms({ action = 'disable' })\"";
              on-resume = "${hyprctl} dispatch \"hl.dsp.dpms({ action = 'enable' })\"";
            }
          ];
        };
    };

    # The lockscreen must survive hypridle restarts and Home Manager updates.
    # Start it only on lock requests; repeated starts leave an active lock alone.
    # TODO: Report upstream to Home Manager: restarting hypridle during activation
    # kills a directly launched hyprlock in its cgroup, leaving the session locked.
    systemd.user.services.hyprlock = {
      Unit = {
        Description = "Hyprland lockscreen";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        ConditionEnvironment = "WAYLAND_DISPLAY";
        X-SwitchMethod = "keep-old";
      };
      Service = {
        Type = "exec";
        ExecStart = "${config.programs.hyprlock.package}/bin/hyprlock";
        Restart = "on-failure";
        RestartSec = 1;
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
      configType = "lua";
      # NixOS owns portal packages/config for the desktop session. Keep Home
      # Manager from exposing a second per-user portal view while still letting it
      # manage Hyprland config and reload hooks.
      portalPackage = null;
      xwayland.enable = true;
      systemd.enable = true;
      settings = {
        config = {
          # Let a replacement lockscreen recover a locked session after failure.
          misc.allow_session_lock_restore = true;

          # Wake even if hypridle restarted while DPMS was off and lost its idle state.
          misc.key_press_enables_dpms = true;

          general = {
            gaps_in = 5;
            gaps_out = 2;
          };

          ecosystem = {
            no_donation_nag = true;
            no_update_news = true;
          };

          animations = {
            enabled = false;
          };

          xwayland = {
            # https://wiki.hypr.land/Configuring/XWayland/
            force_zero_scaling = true;
          };

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
                tap_to_click = true;
              };
            };
        };

        on._args = [
          "hyprland.start"
          (lua ''function() hl.exec_cmd("waybar") end'')
        ];

        # Keep XWayland scaling local to this session so SSH-forwarded X11 apps
        # do not inherit it under XQuartz.
        env = [
          {
            _args = [
              "GDK_SCALE"
              "2"
            ];
          }
          {
            _args = [
              "XCURSOR_SIZE"
              "64"
            ];
          }
        ];

        window_rule = {
          name = "openssh-authentication";
          match.title = "^OpenSSH authentication$";
          stay_focused = true;
        };

        monitor = map renderMonitor displays;
        workspace_rule = workspaceMonitorRules;

        bind = [
          (bind "${super} + H" ''hl.dsp.focus({ direction = "left" })'')
          (bind "${super} + J" ''hl.dsp.focus({ direction = "down" })'')
          (bind "${super} + K" ''hl.dsp.focus({ direction = "up" })'')
          (bind "${super} + L" ''hl.dsp.focus({ direction = "right" })'')
          (bind "${super} + SHIFT + H" ''hl.dsp.window.swap({ direction = "left" })'')
          (bind "${super} + SHIFT + J" ''hl.dsp.window.swap({ direction = "down" })'')
          (bind "${super} + SHIFT + K" ''hl.dsp.window.swap({ direction = "up" })'')
          (bind "${super} + SHIFT + L" ''hl.dsp.window.swap({ direction = "right" })'')

          (bind "${super} + SHIFT + Right" "hl.dsp.window.resize({ x = 50, y = 0, relative = true })")
          (bind "${super} + SHIFT + Left" "hl.dsp.window.resize({ x = -50, y = 0, relative = true })")
          (bind "${super} + SHIFT + Up" "hl.dsp.window.resize({ x = 0, y = -50, relative = true })")
          (bind "${super} + SHIFT + Down" "hl.dsp.window.resize({ x = 0, y = 50, relative = true })")

          (bind "${super} + TAB" ''hl.dsp.focus({ workspace = "previous" })'')

          (bind "${super} + SHIFT + F" "hl.dsp.window.fullscreen()")

          (bind "${super} + Q" "hl.dsp.window.close()")
          (bind "${super} + SHIFT + Q" "hl.dsp.exit()")

          (exec "${super} + Return" (lib.getExe pkgs.kitty))
          (exec "${super} + grave" "${pkgs.kitty}/bin/kitten quick-access-terminal")
          (exec "${super} + SPACE" "${lib.getExe pkgs.wofi} --show drun")

          (exec "${cmdButton} + C" "${pkgs.wl-clipboard}/bin/wl-paste --primary | ${pkgs.wl-clipboard}/bin/wl-copy --trim-newline")

          # RE2 has no negative lookahead; exclude kitty from the regular paste.
          (bind "${cmdButton} + V" ''hl.dsp.send_shortcut({ mods = "CTRL", key = "v", window = "class:^([^k]|k($|[^i]|i($|[^t]|t($|[^t]|t($|[^y])))))*$" })'')
          (bind "${cmdButton} + V" ''hl.dsp.send_shortcut({ mods = "CTRL SHIFT", key = "v", window = "class:^kitty$" })'')

        ]
        ++ workspaceBindings;
      };
    };
  };
}
