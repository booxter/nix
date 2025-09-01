# TODO: rename the module to "desktop"?
{ lib, config, pkgs, ... }:
let
  inherit (pkgs.stdenv) isDarwin;
  sketchybar = "${config.programs.sketchybar.finalPackage}/bin/sketchybar";

  workspaceCount = 9;
  getBindings = { prefix, action }: lib.mergeAttrsList (
    map (i: let
      idx = toString (i + 1);
    in {
      "${prefix}-${idx}" = "${action} ${idx}";
    }) (lib.range 0 (workspaceCount - 1))
  );
in
{
  programs.aerospace = {
    enable = isDarwin;
    launchd.enable = true;

    # ex: https://nikitabobko.github.io/AeroSpace/guide.html#default-config
    userSettings = {
      gaps = {
        outer.left = 2;
        outer.right = 2;
        outer.top = 36;
        outer.bottom = 2;
        inner.horizontal = 10;
        inner.vertical = 10;
      };
      mode.main.binding = {
        alt-h = "focus left";
        alt-j = "focus down";
        alt-k = "focus up";
        alt-l = "focus right";

        alt-shift-h = "move left";
        alt-shift-j = "move down";
        alt-shift-k = "move up";
        alt-shift-l = "move right";

        alt-minus = "resize smart -50";
        alt-equal = "resize smart +50";

        alt-tab = "workspace-back-and-forth";
        alt-shift-tab = "move-workspace-to-monitor --wrap-around next";

        alt-slash = "layout tiles horizontal vertical";
        alt-comma = "layout accordion horizontal vertical";
      }
      // getBindings { prefix = "alt"; action = "workspace"; }
      // getBindings { prefix = "alt-shift"; action = "move-node-to-workspace"; };
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

  programs.sketchybar = {
    enable = true;
    config = builtins.readFile ./sketchybarrc;
    service.enable = false;
    extraPackages = [ pkgs.aerospace ];
  };

  home.file.".config/sketchybar/plugins/aerospace.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      if [ "$1" = "$FOCUSED_WORKSPACE" ]; then
        ${sketchybar} --set $NAME background.drawing=on
      else
        ${sketchybar} --set $NAME background.drawing=off
      fi
    '';
  };
}
