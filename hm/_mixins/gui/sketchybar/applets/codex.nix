{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.sketchybar.codex;
  codexCfg = config.host.hm.dev.codex;
  codexTools = (import ../../../dev/agents/codex/pkgs { inherit pkgs; }).codex-usage-status;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
  personalScript = ''
    sketchybar --add item codex.5h ${cfg.position} \
               --set codex.5h script="$PLUGIN_DIR/codex.sh" \
                              update_freq=60 \
                              icon.drawing=off \
                              label.padding_left=6 \
                              label.padding_right=6 \
                              background.border_width=0 \
                              background.corner_radius=6 \
                              background.height=24 \
               --subscribe codex.5h system_woke \
               --add item codex.weekly ${cfg.position} \
               --set codex.weekly updates=off \
                                  icon.drawing=off \
                                  label.padding_left=6 \
                                  label.padding_right=6 \
                                  background.border_width=0 \
                                  background.corner_radius=6 \
                                  background.height=24 \
               --add item codex.resets ${cfg.position} \
               --set codex.resets script="$PLUGIN_DIR/codex.sh" \
                                 click_script="sketchybar --set codex.resets popup.drawing=toggle" \
                                 icon.drawing=off \
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
               --subscribe codex.resets mouse.entered mouse.exited \
               --add item codex.resets.expiry popup.codex.resets \
               --set codex.resets.expiry updates=off \
                                        icon.drawing=off \
                                        label.padding_left=8 \
                                        label.padding_right=8 \
                                        background.border_width=0 \
                                        background.height=24
  '';
  corporateScript = ''
    sketchybar --add item codex.work ${cfg.position} \
               --set codex.work script="$PLUGIN_DIR/codex-corporate.sh" \
                                update_freq=60 \
                                icon.drawing=off \
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
               --subscribe codex.work system_woke mouse.entered mouse.exited \
               --add item codex.work.credits popup.codex.work \
               --set codex.work.credits updates=off \
                                      icon.drawing=off \
                                      label.padding_left=8 \
                                      label.padding_right=8 \
                                      background.border_width=0 \
                                      background.height=24 \
               --add item codex.work.reset popup.codex.work \
               --set codex.work.reset updates=off \
                                    icon.drawing=off \
                                    label.padding_left=8 \
                                    label.padding_right=8 \
                                    background.border_width=0 \
                                    background.height=24
  '';
  accountConfigs = {
    personal = {
      plugin = "codex";
      executable = "codex-sketchybar";
      script = personalScript;
    };
    corporate = {
      plugin = "codex-corporate";
      executable = "codex-work-sketchybar";
      script = corporateScript;
    };
  };
  accountConfig = accountConfigs.${codexCfg.usage.account};
in
{
  options.host.hm.sketchybar.codex = mkAppletOptions {
    description = "Codex usage";
    defaultPosition = "left";
    defaultOrder = 300;
  };

  config = {
    assertions = [
      {
        assertion = !cfg.enable || codexCfg.enable;
        message = "host.hm.sketchybar.codex requires host.hm.dev.codex.";
      }
    ];

    host.hm.sketchybar.internal.applets.codex = lib.mkIf cfg.enable {
      inherit (cfg) position order;
      inherit (accountConfig) script;
      plugins = [ accountConfig.plugin ];
      pluginPackages.${accountConfig.plugin} = {
        package = codexTools;
        inherit (accountConfig) executable;
      };
    };
  };
}
