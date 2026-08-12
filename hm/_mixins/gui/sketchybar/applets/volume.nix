{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.volume;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.volume = mkAppletOptions {
    description = "volume status";
    defaultEnable = true;
    defaultPosition = "right";
    defaultOrder = 600;
  };

  config.host.hm.sketchybar.internal.applets.volume = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "volume" ];
    script = ''
      sketchybar --add item volume ${cfg.position} \
                 --set volume script="$PLUGIN_DIR/volume.sh" \
                 --subscribe volume volume_change
    '';
  };
}
