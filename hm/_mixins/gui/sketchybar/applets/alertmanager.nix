{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.alertmanager;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.alertmanager =
    mkAppletOptions {
      description = "firing Alertmanager alerts";
      defaultPosition = "right";
      defaultOrder = 100;
    }
    // {
      url = lib.mkOption {
        type = lib.types.str;
        description = "mTLS-protected Alertmanager alerts API URL.";
      };

      grafanaUrl = lib.mkOption {
        type = lib.types.str;
        description = "Grafana alert groups page opened from the applet popup.";
      };

      clientCertificate = lib.mkOption {
        type = lib.types.str;
        description = "Path to the Alertmanager mTLS client certificate.";
      };

      clientKey = lib.mkOption {
        type = lib.types.str;
        description = "Path to the Alertmanager mTLS client key.";
      };
    };

  config.host.hm.sketchybar.internal.applets.alertmanager = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "alertmanager" ];
    script = ''
      sketchybar --add item alertmanager ${cfg.position} \
                 --set alertmanager script="$PLUGIN_DIR/alertmanager.sh" \
                                    update_freq=60 \
                                    drawing=off \
                                    icon.padding_left=6 \
                                    icon.padding_right=2 \
                                    label.padding_left=2 \
                                    label.padding_right=6 \
                                    popup.align=right \
                                    popup.background.color="$BACKGROUND_COLOR" \
                                    popup.background.border_color="$BACKGROUND_BORDER_COLOR" \
                                    popup.background.border_width=1 \
                                    popup.background.corner_radius=6 \
                 --subscribe alertmanager system_woke mouse.clicked

      for index in {0..7}; do
        sketchybar --add item "alertmanager.alert.$index" popup.alertmanager \
                   --set "alertmanager.alert.$index" updates=off \
                                                       drawing=off \
                                                       icon.drawing=off \
                                                       label.align=left \
                                                       label.padding_left=8 \
                                                       label.padding_right=8 \
                                                       background.border_width=0 \
                                                       background.height=24
      done

      sketchybar --add item alertmanager.more popup.alertmanager \
                 --set alertmanager.more updates=off \
                                         drawing=off \
                                         icon.drawing=off \
                                         label.align=left \
                                         label.padding_left=8 \
                                         label.padding_right=8 \
                                         background.border_width=0 \
                                         background.height=24

      sketchybar --add item alertmanager.grafana popup.alertmanager \
                 --set alertmanager.grafana updates=off \
                                            icon="󰈹" \
                                            icon.padding_left=8 \
                                            icon.padding_right=4 \
                                            label="Open Grafana" \
                                            label.align=left \
                                            label.padding_left=4 \
                                            label.padding_right=8 \
                                            background.border_width=0 \
                                            background.height=24 \
                                            click_script="/usr/bin/open ${lib.escapeShellArg cfg.grafanaUrl}; sketchybar --set alertmanager popup.drawing=off"
    '';
  };
}
