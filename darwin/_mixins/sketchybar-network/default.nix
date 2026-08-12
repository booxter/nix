{ config, lib, ... }:
let
  cfg = config.host.sketchybar.network;
  username = config.host.username;
in
{
  options.host.sketchybar.network.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.host.userEnvironment.features.gui.enable;
    description = "Whether SketchyBar should display LAN/WAN traffic rates.";
  };

  config = lib.mkIf cfg.enable {
    host.observability.lanWan.enable = true;
    home-manager.users.${username}.programs.sketchybarNetwork.enable = true;
  };
}
