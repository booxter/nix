{
  lib,
  config,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  cfg = config.host.hm.aerospace;
  guiCfg = osConfig.host.userEnvironment.features.gui;
  sketchybar = "${config.programs.sketchybar.finalPackage}/bin/sketchybar";
  sketchybarHeight = 30; # TODO: parametrize it?

  aerospaceX11Actions = pkgs.callPackage ./pkgs { };
  defaultWorkspaceNames = map toString (lib.range 1 cfg.numberedWorkspaces);
  requestedWorkspaceNames = builtins.attrNames cfg.workspaces;
  workspaceNames = lib.unique (defaultWorkspaceNames ++ requestedWorkspaceNames);
  workspaceRules = lib.concatMap (
    workspaceName:
    map (appBundleId: {
      "if" = "test %{app-bundle-id} = ${appBundleId}";
      run = [ "move-node-to-workspace ${workspaceName}" ];
    }) cfg.workspaces.${workspaceName}.appBundleIds
  ) requestedWorkspaceNames;
  workspaceMonitorAssignments = lib.mapAttrs (_: workspace: workspace.monitor) (
    lib.filterAttrs (_: workspace: workspace.monitor != null) cfg.workspaces
  );
  moveCommand =
    direction:
    if cfg.x11.enable then
      "exec-and-forget ${lib.getExe' aerospaceX11Actions "aerospace-x11-aware-move"} ${direction}"
    else
      "move ${direction}";
  resizeCommand =
    delta:
    if cfg.x11.enable then
      "exec-and-forget ${lib.getExe' aerospaceX11Actions "aerospace-x11-aware-resize"} ${delta}"
    else
      "resize smart ${delta}";
  getBindings =
    { prefix, action }:
    lib.mergeAttrsList (
      map (i: {
        "${prefix}-${i}" = "${action} ${i}";
      }) workspaceNames
    );
in
{
  options.host.hm.aerospace = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = isDarwin;
      description = "Whether to enable the AeroSpace window manager.";
    };

    x11.enable = lib.mkOption {
      type = lib.types.bool;
      default = guiCfg.x11.enable;
      description = "Whether AeroSpace actions should support X11 windows.";
    };

    numberedWorkspaces = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = 4;
      description = "Number of persistent numbered workspaces.";
    };

    workspaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            appBundleIds = lib.mkOption {
              type = lib.types.listOf lib.types.nonEmptyStr;
              default = [ ];
              description = "Application bundle identifiers assigned to this workspace.";
            };

            monitor = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Monitor to which this workspace is assigned.";
            };
          };
        }
      );
      default = { };
      description = "Application-requested AeroSpace workspaces.";
    };

    workspaceNames = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.nonEmptyStr;
      readOnly = true;
      internal = true;
      description = "AeroSpace default and application-requested workspace names.";
    };
  };

  config = lib.mkMerge [
    { host.hm.aerospace.workspaceNames = workspaceNames; }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = isDarwin;
          message = "host.hm.aerospace is only supported on Darwin.";
        }
        {
          assertion = !cfg.x11.enable || guiCfg.x11.enable;
          message = "host.hm.aerospace.x11 requires features.gui.x11.";
        }
      ];

      programs.aerospace = {
        enable = true;
        launchd.enable = true;

        # ex: https://nikitabobko.github.io/AeroSpace/guide.html#default-config
        settings = {
          config-version = 2;
          persistent-workspaces = workspaceNames;

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

          on-window-detected = workspaceRules;

          workspace-to-monitor-force-assignment = workspaceMonitorAssignments;

          enable-normalization-opposite-orientation-for-nested-containers = false;

          automatically-unhide-macos-hidden-apps = false;

          exec-on-workspace-change = [
            "/bin/bash"
            "-c"
            "${sketchybar} --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE"
          ];
        };
      };
    })
  ];
}
