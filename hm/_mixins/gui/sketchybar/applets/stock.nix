{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.stock;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.stock = mkAppletOptions {
    description = "stock quotes";
    defaultEnable = true;
    defaultPosition = "right";
    defaultOrder = 1000;
  };

  config.host.hm.sketchybar.internal.applets.stock = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "stock" ];
    script = ''
      sketchybar --add item stock ${cfg.position} \
                 --set stock script="$PLUGIN_DIR/stock.sh" update_freq=300
    '';
  };
}
