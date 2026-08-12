{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.host.hm.obsidian.enable = lib.mkEnableOption "Obsidian";

  config = lib.mkIf config.host.hm.obsidian.enable {
    home.packages = [ pkgs.obsidian ];
  };
}
