{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.ipAddress;
  networkCfg = config.host.hm.sketchybar.network;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.ipAddress = mkAppletOptions {
    description = "network address status";
    defaultEnable = true;
    defaultPosition = "right";
    defaultOrder = 800;
  };

  config.host.hm.sketchybar.internal.applets.ipAddress = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "ip_address" ];
    # Source: https://github.com/nicolas-martin/awesome-sketchybar/blob/b710fe2fe03c2725efa5ae4cd8c6503a3ffc15be/plugins/Combined-Wifi-Status-IP-Address-and-VPN-.md
    script = ''
      sketchybar --add item ip_address ${cfg.position} \
                 --set ip_address script="$PLUGIN_DIR/ip_address.sh" \
                                  update_freq=30 \
                                  label.drawing=off \
                                  padding_left=2 \
                                  padding_right=8 \
                                  background.border_width=0 \
                                  background.corner_radius=6 \
                                  background.height=24 \
                 --subscribe ip_address wifi_change mouse.clicked

      sketchybar --add bracket status ip_address${lib.optionalString networkCfg.enable " network.up network.down"} \
                 --set status background.color="$BACKGROUND_COLOR" \
                              background.border_color="$BLUE"
    '';
  };
}
