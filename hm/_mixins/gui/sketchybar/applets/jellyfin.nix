{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.jellyfin;
  inherit (config.lib.stylix) colors;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.jellyfin =
    mkAppletOptions {
      description = "active Jellyfin streams";
      defaultPosition = "right";
      defaultOrder = 200;
    }
    // {
      metricsUrl = lib.mkOption {
        type = lib.types.str;
        description = "mTLS-protected Jellyfin exporter metrics URL.";
      };

      dashboardUrl = lib.mkOption {
        type = lib.types.str;
        description = "Grafana media dashboard opened from the applet popup.";
      };

      clientCertificate = lib.mkOption {
        type = lib.types.str;
        description = "Path to the Jellyfin exporter mTLS client certificate.";
      };

      clientKey = lib.mkOption {
        type = lib.types.str;
        description = "Path to the Jellyfin exporter mTLS client key.";
      };
    };

  config.host.hm.sketchybar.internal.applets.jellyfin = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "jellyfin" ];
    script = ''
      sketchybar --add item jellyfin ${cfg.position} \
                 --set jellyfin script="$PLUGIN_DIR/jellyfin.sh" \
                                update_freq=30 \
                                drawing=off \
                                icon="󰼁" \
                                icon.font="JetBrainsMono Nerd Font:Regular:16.0" \
                                icon.color="0xff${colors.base0E}" \
                                icon.padding_left=6 \
                                icon.padding_right=2 \
                                label.padding_left=2 \
                                label.padding_right=6 \
                                popup.align=right \
                                popup.background.color="$BACKGROUND_COLOR" \
                                popup.background.border_color="$BACKGROUND_BORDER_COLOR" \
                                popup.background.border_width=1 \
                                popup.background.corner_radius=6 \
                 --subscribe jellyfin system_woke mouse.clicked

      sketchybar --add item jellyfin.bandwidth popup.jellyfin \
                 --set jellyfin.bandwidth updates=off \
                                         drawing=off \
                                         icon.drawing=off \
                                         label.align=left \
                                         label.padding_left=8 \
                                         label.padding_right=8 \
                                         background.border_width=0 \
                                         background.height=24

      for index in {0..7}; do
        sketchybar --add item "jellyfin.session.$index" popup.jellyfin \
                   --set "jellyfin.session.$index" updates=off \
                                                   drawing=off \
                                                   icon.drawing=off \
                                                   label.align=left \
                                                   label.padding_left=8 \
                                                   label.padding_right=8 \
                                                   background.border_width=0 \
                                                   background.height=24
      done

      sketchybar --add item jellyfin.dashboard popup.jellyfin \
                 --set jellyfin.dashboard updates=off \
                                         icon="󰈹" \
                                         icon.padding_left=8 \
                                         icon.padding_right=4 \
                                         label="Open Grafana" \
                                         label.align=left \
                                         label.padding_left=4 \
                                         label.padding_right=8 \
                                         background.border_width=0 \
                                         background.height=24 \
                                         click_script="/usr/bin/open ${lib.escapeShellArg cfg.dashboardUrl}; sketchybar --set jellyfin popup.drawing=off"
    '';
  };
}
