{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.seerr;
  tools = pkgs.callPackage ./tools { };
  user = "seerr";
in
{
  config = lib.mkIf (cfg != null) {
    services.seerr = {
      enable = true;
      package = pkgs.seerr;
      configDir = cfg.stateDir;
    };

    environment.systemPackages = [ tools.package ];

    users.groups.${user} = { };
    users.users.${user} = {
      group = user;
      home = "/var/empty";
      isSystemUser = true;
    };

    # TODO(seerr): migrate the legacy /data state tree to /var/lib/seerr so
    # the upstream module can own directory creation through StateDirectory.
    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${user} ${user} - -"
    ];

    systemd.services.seerr.serviceConfig = {
      Group = user;
      ReadWritePaths = [ cfg.stateDir ];
      StateDirectory = lib.mkForce null;
      User = user;
      WorkingDirectory = cfg.stateDir;
    };

    host.backups.sources.seerr-database = {
      title = "Seerr";
      database = {
        type = "sqlite";
        path = "${cfg.stateDir}/db/db.sqlite3";
        stagingDir = "${cfg.stateDir}-backup/latest";
        extraCopies = [
          { source = "${cfg.stateDir}/settings.json"; }
        ];
      };
    };
  };
}
