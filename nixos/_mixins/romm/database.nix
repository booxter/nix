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
  tmpfilesUnits = [
    "systemd-tmpfiles-setup.service"
    "systemd-tmpfiles-resetup.service"
  ];
  initCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.toolsPackage "romm-db-init")
    "--socket"
    "/run/mysqld/mysqld.sock"
  ];
in
{
  config = lib.mkIf (cfg.enable && model.ready) {
    services.mysql = {
      enable = true;
      package = pkgs.mariadb;
      dataDir = cfg.database.dataDir;
      settings.mysqld.skip-networking = true;
    };

    systemd.services = {
      mysql.after = tmpfilesUnits;
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
        ++ tmpfilesUnits;
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
