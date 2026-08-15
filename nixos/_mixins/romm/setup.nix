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
  baseUnits = model.units.user ++ [ "network-online.target" ];
  setupConfig = pkgs.writeText "romm-setup.json" (
    builtins.toJSON {
      image = model.image;
      environment = model.commonEnvironment;
      mounts = map (mount: {
        source = mount.source;
        target = mount.target;
        read_only = mount.readOnly;
      }) model.containerMounts;
    }
  );
  command = utils.escapeSystemdExecArgs [
    (lib.getExe' model.toolsPackage "romm-run-setup")
    "--socket-url"
    model.podmanSocket
    "--config"
    setupConfig
    "--environment-file"
    config.sops.templates."romm.env".path
  ];
in
{
  config = lib.mkIf (cfg != null && model.ready) {
    systemd.services.romm-setup = {
      description = "Run RomM database migrations and startup tasks";
      wantedBy = [ "multi-user.target" ];
      wants = baseUnits ++ model.units.setupBefore;
      requires = [
        "romm-web-assets.service"
        "romm-backup.service"
      ];
      after = baseUnits ++ model.units.setupBefore ++ model.units.tmpfiles;
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      environment = model.runtimeEnvironment;
      serviceConfig = {
        Type = "oneshot";
        User = model.user;
        Group = model.storageGroup;
        WorkingDirectory = cfg.stateDir;
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5s";
        ExecStart = command;
        TimeoutStartSec = "10min";
      };
    };
  };
}
