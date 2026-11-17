{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.sketchybar.claude;
  claudeTools = pkgs.callPackage ../../../dev/agents/claude/statusline { };
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.claude = mkAppletOptions {
    description = "Claude usage";
    defaultPosition = "left";
    defaultOrder = 310;
  };

  config = {
    assertions = [
      {
        assertion = !cfg.enable || config.programs.claude-code.enable;
        message = "host.hm.sketchybar.claude requires programs.claude-code.";
      }
    ];

    host.hm.sketchybar.internal.applets.claude = lib.mkIf cfg.enable {
      inherit (cfg) position order;
      # The Claude status line saves the usage shown here; see
      # claude_statusline/usage.py for the limitations that follow.
      script = ''
        sketchybar --add item claude.5h ${cfg.position} \
                   --set claude.5h script="$PLUGIN_DIR/claude.sh" \
                                   update_freq=60 \
                                   icon=":claude:" \
                                   icon.font="$APP_ICON_FONT" \
                                   icon.padding_left=6 \
                                   label.padding_left=6 \
                                   label.padding_right=6 \
                                   background.border_width=0 \
                                   background.corner_radius=6 \
                                   background.height=24 \
                   --subscribe claude.5h system_woke \
                   --add item claude.weekly ${cfg.position} \
                   --set claude.weekly updates=off \
                                       icon.drawing=off \
                                       label.padding_left=6 \
                                       label.padding_right=6 \
                                       background.border_width=0 \
                                       background.corner_radius=6 \
                                       background.height=24
      '';
      plugins = [ "claude" ];
      pluginPackages.claude = {
        package = claudeTools;
        executable = "claude-sketchybar";
      };
    };
  };
}
