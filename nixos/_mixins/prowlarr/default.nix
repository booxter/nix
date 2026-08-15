{ config, lib, ... }:
let
  cfg = config.host.prowlarr;
in
{
  imports = [
    (import ../servarr {
      name = "prowlarr";
      media = false;
    })
  ];

  config = lib.mkIf (cfg != null) {
    systemd.tmpfiles.settings."10-prowlarr".${cfg.stateDir}.d = {
      user = lib.mkForce "nobody";
      group = lib.mkForce "nogroup";
    };
  };
}
