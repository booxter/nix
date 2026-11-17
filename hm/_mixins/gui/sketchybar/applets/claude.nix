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
  # The Claude status line saves the usage shown here; see
  # claude_statusline/usage.py for the limitations that follow.
  personalScript = ''
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
  # The spend comes from Claude's usage API; see claude_statusline/spend.py.
  corporateScript = ''
    sketchybar --add item claude.work ${cfg.position} \
               --set claude.work script="$PLUGIN_DIR/claude-corporate.sh" \
                                 update_freq=300 \
                                 icon=":claude:" \
                                 icon.font="$APP_ICON_FONT" \
                                 icon.padding_left=6 \
                                 label.padding_left=6 \
                                 label.padding_right=6 \
                                 background.border_width=0 \
                                 background.corner_radius=6 \
                                 background.height=24 \
                                 popup.align=${cfg.position} \
                                 popup.background.color="$BACKGROUND_COLOR" \
                                 popup.background.border_color="$BACKGROUND_BORDER_COLOR" \
                                 popup.background.border_width=1 \
                                 popup.background.corner_radius=6 \
               --subscribe claude.work system_woke mouse.entered mouse.exited \
               --add item claude.work.spend popup.claude.work \
               --set claude.work.spend updates=off \
                                       icon.drawing=off \
                                       label.padding_left=8 \
                                       label.padding_right=8 \
                                       background.border_width=0 \
                                       background.height=24 \
               --add item claude.work.reset popup.claude.work \
               --set claude.work.reset updates=off \
                                       icon.drawing=off \
                                       label.padding_left=8 \
                                       label.padding_right=8 \
                                       background.border_width=0 \
                                       background.height=24
  '';
  accountConfigs = {
    personal = {
      plugin = "claude";
      executable = "claude-sketchybar";
      script = personalScript;
    };
    corporate = {
      plugin = "claude-corporate";
      executable = "claude-work-sketchybar";
      script = corporateScript;
    };
  };
  accountConfig = accountConfigs.${config.host.hm.dev.claude.usage.account};
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
      inherit (accountConfig) script;
      plugins = [ accountConfig.plugin ];
      pluginPackages.${accountConfig.plugin} = {
        package = claudeTools;
        inherit (accountConfig) executable;
      };
    };
  };
}
