{
  config,
  lib,
  pkgs,
  rommModel,
  utils,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg;
  initCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' model.toolsPackage "romm-db-init")
    "--socket"
    "/run/mysqld/mysqld.sock"
  ];
in
{
  config = lib.mkIf (cfg != null && model.ready) {
    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      dataDir = cfg.database.dataDir;
      settings.mysqld.skip-networking = true;
    };

    systemd.services = {
      mysql.after = model.units.tmpfiles;
      romm-db-init = {
        description = "Initialize RomM MariaDB database";
        wants = [
          "mysql.service"
          "sops-install-secrets.service"
        ];
        after = [
          "mysql.service"
          "sops-install-secrets.service"
        ]
        ++ model.units.tmpfiles;
        unitConfig.RequiresMountsFor = builtins.dirOf cfg.database.dataDir;
        serviceConfig = {
          Type = "oneshot";
          EnvironmentFile = config.sops.templates."romm.env".path;
          ExecStart = initCommand;
        };
      };
    };
  };
}
