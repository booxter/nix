{ config, lib, ... }:
let
  cfg = config.host.sketchybar.network;
  username = config.host.username;
in
{
  options.host.sketchybar.network.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether SketchyBar should display LAN/WAN traffic rates.";
  };

  config = lib.mkIf cfg.enable {
    home-manager.users.${username}.host.hm.sketchybar.network.enable = true;
  };
}
