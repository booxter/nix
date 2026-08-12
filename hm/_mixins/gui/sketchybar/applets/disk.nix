{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.disk;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.disk = mkAppletOptions {
    description = "disk usage";
    defaultEnable = true;
    defaultPosition = "left";
    defaultOrder = 200;
  };

  config.host.hm.sketchybar.internal.applets.disk = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "disk" ];
    script = ''
      sketchybar --add item disk ${cfg.position} \
                 --set disk script="$PLUGIN_DIR/disk.sh" \
                            update_freq=60 \
                            icon.drawing=off \
                 --subscribe disk system_woke
    '';
  };
}
