{ config, lib, ... }:
let
  cfg = config.host.seerr;
in
{
  config = lib.mkIf cfg.enable {
    services.seerr = {
      enable = true;
      package = cfg.package;
      configDir = cfg.stateDir;
    };

    environment.systemPackages = lib.optional (
      cfg.maintenanceToolsPackage != null
    ) cfg.maintenanceToolsPackage;

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      group = cfg.group;
      home = "/var/empty";
      isSystemUser = true;
    };

    # TODO(seerr): migrate the legacy /data state tree to /var/lib/seerr so
    # the upstream module can own directory creation through StateDirectory.
    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.seerr.serviceConfig = {
      EnvironmentFile = config.sops.templates."seerr-environment".path;
      Group = cfg.group;
      ReadWritePaths = [ cfg.stateDir ];
      StateDirectory = lib.mkForce null;
      User = cfg.user;
      WorkingDirectory = cfg.stateDir;
    };
  };
}
