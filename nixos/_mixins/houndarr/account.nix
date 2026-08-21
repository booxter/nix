{ config, lib, ... }:
let
  cfg = config.host.houndarr;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      description = "Houndarr service user";
      isSystemUser = true;
      group = cfg.group;
      home = "/var/empty";
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} - -"
    ];
  };
}
