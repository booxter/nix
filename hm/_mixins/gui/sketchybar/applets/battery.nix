{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.battery;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.battery = mkAppletOptions {
    description = "battery status";
    defaultEnable = true;
    defaultPosition = "right";
    defaultOrder = 700;
  };

  config.host.hm.sketchybar.internal.applets.battery = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "battery" ];
    script = ''
      sketchybar --add item battery ${cfg.position} \
                 --set battery update_freq=120 script="$PLUGIN_DIR/battery.sh" \
                 --subscribe battery system_woke power_source_change
    '';
  };
}
