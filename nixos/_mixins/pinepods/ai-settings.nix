{
  config,
  lib,
  pinepodsModel,
  utils,
  ...
}:
let
  inherit (pinepodsModel) cfg databaseName ollamaTunnelPort;
in
{
  config = lib.mkIf (cfg != null) {
    systemd.services.pinepods-ai-settings = {
      description = "Configure PinePods ad detection";
      wantedBy = [ "multi-user.target" ];
      requires = [ "podman-pinepods.service" ];
      after = [ "podman-pinepods.service" ];
      partOf = [ "podman-pinepods.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe' config.services.postgresql.package "psql")
          "--no-psqlrc"
          "--dbname"
          databaseName
          "--set=ON_ERROR_STOP=1"
          "--set=model=${cfg.adDetectionModel}"
          "--set=url=http://10.0.2.2:${toString ollamaTunnelPort}/v1"
          "--single-transaction"
          "--file=${./ai-settings.sql}"
        ];
      };
    };
  };
}
