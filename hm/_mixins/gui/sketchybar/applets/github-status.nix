{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.githubStatus;
  inherit (config.lib.stylix) colors;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.githubStatus =
    mkAppletOptions {
      description = "GitHub service status";
      defaultEnable = true;
      defaultPosition = "right";
      defaultOrder = 400;
    }
    // {
      components = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        example = [
          "Git Operations"
          "Pull Requests"
          "Actions"
        ];
        description = "Exact GitHub Status component names to watch. An empty list watches the entire status page.";
      };
    };

  config.host.hm.sketchybar.internal.applets.githubStatus = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "github-status" ];
    script = ''
      sketchybar --add item github-status ${cfg.position} \
                 --set github-status script="$PLUGIN_DIR/github-status.sh" \
                                     update_freq=60 \
                                     drawing=off \
                                     icon="" \
                                     icon.font="$ICON_BASE_FONT:Regular:16.0" \
                                     icon.color="0xff${colors.base08}" \
                                     icon.padding_left=6 \
                                     icon.padding_right=6 \
                                     label.drawing=off \
                                     click_script="/usr/bin/open https://www.githubstatus.com" \
                 --subscribe github-status system_woke
    '';
  };
}
