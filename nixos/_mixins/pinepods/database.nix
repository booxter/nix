{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.pinepods;
  passwordSecret = "pinepods/postgresql/password";
  setPasswordCommand = utils.escapeSystemdExecArgs [
    (lib.getExe pkgs.postgresql-role-password)
    "--database"
    cfg.databaseName
    "--role"
    cfg.user
    "--password-file"
    config.sops.secrets.${passwordSecret}.path
  ];
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets.${passwordSecret} = {
      owner = "postgres";
      group = "postgres";
      mode = "0400";
      restartUnits = [
        "pinepods-postgresql-password.service"
        "podman-pinepods.service"
      ];
    };

    services.postgresql = {
      enable = true;
      enableTCPIP = true;
      settings = {
        listen_addresses = lib.mkForce "127.0.0.1";
        password_encryption = "scram-sha-256";
      };
      authentication = lib.mkAfter ''
        host postgres ${cfg.user} 127.0.0.1/32 scram-sha-256
        host ${cfg.databaseName} ${cfg.user} 127.0.0.1/32 scram-sha-256
      '';
      ensureDatabases = [ cfg.databaseName ];
      ensureUsers = [
        {
          name = cfg.user;
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.services.pinepods-postgresql-password = {
      description = "Apply PinePods PostgreSQL password";
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql-setup.service" ];
      wants = [ "sops-install-secrets.service" ];
      after = [
        "postgresql-setup.service"
        "sops-install-secrets.service"
      ];
      before = [ "podman-pinepods.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        ExecStart = setPasswordCommand;
      };
    };
  };
}
