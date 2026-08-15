{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.aerospace;
  workspaceNames = config.host.hm.aerospace.workspaceNames;
  inherit (config.lib.stylix) colors;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.aerospace = mkAppletOptions {
    description = "AeroSpace workspaces";
    defaultPosition = "left";
    defaultOrder = 100;
  };

  config.assertions = [
    {
      assertion = !cfg.enable || config.host.hm.aerospace.enable;
      message = "host.hm.sketchybar.aerospace requires host.hm.aerospace.";
    }
  ];

  config.host.hm.sketchybar.internal.applets.aerospace = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "aerospace" ];
    packages = [ config.programs.aerospace.package ];
    script = ''
      sketchybar --add event aerospace_workspace_change
    ''
    + lib.concatMapStringsSep "\n" (
      workspace:
      let
        escapedWorkspace = lib.escapeShellArg workspace;
      in
      ''
        sketchybar --add item space.${workspace} ${cfg.position} \
            --subscribe space.${workspace} aerospace_workspace_change \
            --set space.${workspace} \
            background.color=0x44${colors.base05} \
            background.corner_radius=5 \
            background.height=25 \
            background.drawing=off \
            label=${escapedWorkspace} \
            click_script="aerospace workspace ${escapedWorkspace}" \
            script="$PLUGIN_DIR/aerospace.sh ${escapedWorkspace}"
      ''
    ) workspaceNames;
  };
}
