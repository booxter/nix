{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.network;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.network = mkAppletOptions {
    description = "LAN and WAN traffic rates";
    defaultPosition = "right";
    defaultOrder = 900;
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.enable || config.host.hm.sketchybar.ipAddress.enable;
          message = "host.hm.sketchybar.network requires host.hm.sketchybar.ipAddress.";
        }
      ];
    }
    {
      host.hm.sketchybar.internal.applets.network = lib.mkIf cfg.enable {
        inherit (cfg) position order;
        plugins = [ "network" ];
        script = ''
          sketchybar --add item network.up ${cfg.position} \
                     --set network.up script="$PLUGIN_DIR/network.sh" \
                                      update_freq=20 \
                                      padding_left=2 \
                                      padding_right=2 \
                                      background.border_width=0 \
                                      background.height=24 \
                                      icon=⇡ \
                                      icon.color="$YELLOW" \
                                      label.color="$YELLOW" \
                     --add item network.down ${cfg.position} \
                     --set network.down script="$PLUGIN_DIR/network.sh" \
                                        update_freq=20 \
                                        padding_left=8 \
                                        padding_right=2 \
                                        background.border_width=0 \
                                        background.height=24 \
                                        icon=⇣ \
                                        icon.color="$GREEN" \
                                        label.color="$GREEN"
        '';
      };
    }
  ];
}
