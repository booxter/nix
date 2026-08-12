{ config, lib, ... }:
let
  cfg = config.host.degoog;
in
{
  config = lib.mkIf cfg.enable {
    host.backups.sources.degoog.paths = [ "/var/lib/degoog" ];
  };
}
