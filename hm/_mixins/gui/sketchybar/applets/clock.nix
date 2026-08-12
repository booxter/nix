{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.clock;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.clock = mkAppletOptions {
    description = "the clock";
    defaultEnable = true;
    defaultPosition = "right";
    defaultOrder = 500;
  };

  config.host.hm.sketchybar.internal.applets.clock = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "clock" ];
    script = ''
      sketchybar --add item clock ${cfg.position} \
                 --set clock update_freq=10 icon=􀐫 script="$PLUGIN_DIR/clock.sh"
    '';
  };
}
