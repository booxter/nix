{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.frontApp;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.frontApp = mkAppletOptions {
    description = "the active application";
    defaultEnable = true;
    defaultPosition = "left";
    defaultOrder = 400;
  };

  config.host.hm.sketchybar.internal.applets.frontApp = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "front_app" ];
    script = ''
      sketchybar --add item chevron ${cfg.position} \
                 --set chevron icon=􀁖 label.drawing=off \
                 --add item front_app ${cfg.position} \
                 --set front_app icon.drawing=off script="$PLUGIN_DIR/front_app.sh" \
                 --subscribe front_app front_app_switched
    '';
  };
}
