{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.seerr;
  tools = pkgs.callPackage ./tools { };
in
{
  config = lib.mkIf cfg.enable {
    services.seerr = {
      enable = true;
      package = cfg.package;
      configDir = cfg.stateDir;
    };

    environment.systemPackages = [ tools.package ];

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
      Group = cfg.group;
      ReadWritePaths = [ cfg.stateDir ];
      StateDirectory = lib.mkForce null;
      User = cfg.user;
      WorkingDirectory = cfg.stateDir;
    };
  };
}
