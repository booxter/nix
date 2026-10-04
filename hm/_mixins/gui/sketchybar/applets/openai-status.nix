{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.openaiStatus;
  inherit (config.lib.stylix) colors;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.openaiStatus = mkAppletOptions {
    description = "OpenAI service status";
    defaultEnable = true;
    defaultPosition = "right";
    defaultOrder = 410;
  };

  config.host.hm.sketchybar.internal.applets.openaiStatus = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "openai-status" ];
    script = ''
      sketchybar --add item openai-status ${cfg.position} \
                 --set openai-status script="$PLUGIN_DIR/openai-status.sh" \
                                     update_freq=60 \
                                     drawing=off \
                                     icon="󰚩" \
                                     icon.font="$ICON_BASE_FONT:Regular:16.0" \
                                     icon.color="0xff${colors.base08}" \
                                     icon.padding_left=6 \
                                     icon.padding_right=6 \
                                     label.drawing=off \
                                     click_script="/usr/bin/open https://status.openai.com" \
                 --subscribe openai-status system_woke
    '';
  };
}
