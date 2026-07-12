{
  lib,
  config,
  pkgs,
  isWork,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin;
  sketchybar = "${config.programs.sketchybar.finalPackage}/bin/sketchybar";
  sketchybarHeight = 30; # TODO: parametrize it?

  aerospacePkgs = import ./pkgs { inherit pkgs; };
  workspaceCount = 6;
  moveCommand =
    direction:
    if config.programs.xquartz.enable then
      "exec-and-forget ${lib.getExe aerospacePkgs.aerospace-x11-aware-move} ${direction}"
    else
      "move ${direction}";
  resizeCommand =
    delta:
    if config.programs.xquartz.enable then
      "exec-and-forget ${lib.getExe aerospacePkgs.aerospace-x11-aware-resize} ${delta}"
    else
      "resize smart ${delta}";
  getBindings =
    { prefix, action }:
    lib.mergeAttrsList (
      map
        (i: {
          "${prefix}-${i}" = "${action} ${i}";
        })
        (
          (map toString (lib.range 1 workspaceCount))
          ++ [
            "c" # chat
            "e" # email
            "s" # spotify
          ]
          ++ (lib.optional isWork "t") # teams
        )
    );
in
{
  programs.aerospace = {
    enable = isDarwin;
    launchd.enable = true;

    # ex: https://nikitabobko.github.io/AeroSpace/guide.html#default-config
    settings = {
      gaps = {
        outer.left = 2;
        outer.right = 2;
        outer.top = [
          {
            monitor.built-in = 2;
          }
          (sketchybarHeight + 2)
        ];
        outer.bottom = 2;
        inner.horizontal = 10;
        inner.vertical = 10;
      };
      mode.main.binding = {
        alt-h = "focus left";
        alt-j = "focus down";
        alt-k = "focus up";
        alt-l = "focus right";

        alt-shift-h = moveCommand "left";
        alt-shift-j = moveCommand "down";
        alt-shift-k = moveCommand "up";
        alt-shift-l = moveCommand "right";

        alt-minus = resizeCommand "-50";
        alt-equal = resizeCommand "+50";

        alt-tab = "workspace-back-and-forth";
        alt-shift-tab = "move-workspace-to-monitor --wrap-around next";

        alt-shift-semicolon = "mode service";

        alt-slash = "layout tiles horizontal vertical";
        alt-comma = "layout accordion horizontal vertical";

        alt-shift-f = "fullscreen";

        cmd-h = [ ]; # Disable "hide application"
        cmd-alt-h = [ ]; # Disable "hide others"

        alt-shift-s = "exec-and-forget screencapture -i -c";

        cmd-backtick = "exec-and-forget ${pkgs.kitty}/bin/kitten quick-access-terminal";
        # Use LaunchServices so Kitty starts with the current GUI launchd environment.
        alt-enter = "exec-and-forget /usr/bin/open -n -b net.kovidgoyal.kitty --args --directory ~";
      }
      // getBindings {
        prefix = "alt";
        action = "workspace";
      }
      // getBindings {
        prefix = "alt-shift";
        action = "move-node-to-workspace";
      };

      mode.service.binding = {
        esc = [
          "reload-config"
          "mode main"
        ];
        f = [
          "layout floating tiling"
          "mode main"
        ];
        r = [
          "flatten-workspace-tree"
          "mode main"
        ];

        alt-shift-h = [
          "join-with left"
          "mode main"
        ];
        alt-shift-j = [
          "join-with down"
          "mode main"
        ];
        alt-shift-k = [
          "join-with up"
          "mode main"
        ];
        alt-shift-l = [
          "join-with right"
          "mode main"
        ];
      };

      on-focus-changed = [
        "move-mouse window-lazy-center"
      ];

      on-window-detected = [
        # Chat apps go to C workspace
        {
          "if" = {
            app-id = "com.tinyspeck.slackmacgap";
          };
          run = [ "move-node-to-workspace c" ];
        }
        {
          "if" = {
            app-id = "im.riot.app";
          };
          run = [ "move-node-to-workspace c" ];
        }
        {
          "if" = {
            app-id = "com.tdesktop.Telegram";
          };
          run = [ "move-node-to-workspace c" ];
        }
        # Spotify
        {
          "if" = {
            app-id = "com.spotify.client";
          };
          run = [ "move-node-to-workspace s" ];
        }
        # Jellyfin Desktop on same workspace as Spotify
        {
          "if" = {
            app-id = "org.jellyfin.JellyfinDesktop";
          };
          run = [ "move-node-to-workspace s" ];
        }
        # Email
        {
          "if" = {
            app-id = "org.nixos.thunderbird";
          };
          run = [ "move-node-to-workspace e" ];
        }
      ]
      ++ lib.optionals isWork [
        {
          "if" = {
            app-id = "com.microsoft.teams2";
          };
          run = [ "move-node-to-workspace t" ];
        }
      ];

      workspace-to-monitor-force-assignment = {
        "6" = "secondary";
        "t" = "secondary";
      };

      enable-normalization-opposite-orientation-for-nested-containers = false;

      automatically-unhide-macos-hidden-apps = false;

      after-startup-command = [
        "exec-and-forget ${sketchybar}"
      ];
      exec-on-workspace-change = [
        "/bin/bash"
        "-c"
        "${sketchybar} --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE"
      ];
    };
  };
}
