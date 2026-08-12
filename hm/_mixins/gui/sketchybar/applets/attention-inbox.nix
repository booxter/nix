{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.sketchybar.attentionInbox;
  attentionInbox = pkgs.callPackage ../../../dev/attention-inbox/pkgs { };
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.attentionInbox = mkAppletOptions {
    description = "the attention inbox";
    defaultPosition = "right";
    defaultOrder = 300;
  };

  config.host.hm.sketchybar.internal.applets.attentionInbox = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "attention-inbox" ];
    pluginPackages.attention-inbox = {
      package = attentionInbox;
      executable = "attention-inbox-sketchybar";
    };
    script = ''
      sketchybar --add item attention.inbox ${cfg.position} \
                 --set attention.inbox script="$PLUGIN_DIR/attention-inbox.sh" \
                                       update_freq=1200 \
                                       drawing=off \
                                       icon.drawing=off \
                                       icon.padding_left=6 \
                                       icon.padding_right=2 \
                                       label.padding_left=2 \
                                       label.padding_right=6 \
                                       click_script="sketchybar --set attention.inbox popup.drawing=toggle" \
                                       popup.align=right \
                                       popup.background.color="$BACKGROUND_COLOR" \
                                       popup.background.border_color="$BACKGROUND_BORDER_COLOR" \
                                       popup.background.border_width=1 \
                                       popup.background.corner_radius=6 \
                 --subscribe attention.inbox system_woke

      for index in {0..9}; do
        sketchybar --add item "attention.inbox.$index" popup.attention.inbox \
                   --set "attention.inbox.$index" updates=off \
                                                    drawing=off \
                                                    icon.drawing=off \
                                                    icon.padding_left=8 \
                                                    icon.padding_right=4 \
                                                    label.align=left \
                                                    label.padding_left=8 \
                                                    label.padding_right=8 \
                                                    background.border_width=0 \
                                                    background.height=24
      done
    '';
  };
}
