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
        description = "Grafana alert groups page opened when the applet is clicked.";
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
                                    click_script="/usr/bin/open ${lib.escapeShellArg cfg.grafanaUrl}" \
                 --subscribe alertmanager system_woke
    '';
  };
}
