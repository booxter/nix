{ config, lib, ... }:
let
  inherit (import ./model.nix { inherit config; }) cfg stateDir;
in
{
  imports = [
    ./services/decider.nix
    ./services/qos.nix
    ./services/transmission.nix
  ];

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      description = "Adaptive upload policy controller";
      isSystemUser = true;
      group = cfg.group;
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 ${cfg.user} ${cfg.group} -"
    ]
    ++ lib.optional cfg.metrics.enable "z ${cfg.metrics.directory} 0775 root ${cfg.group} - -";
  };
}
