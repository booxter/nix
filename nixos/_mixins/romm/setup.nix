{
  config,
  lib,
  pkgs,
  storageModel,
  utils,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      pkgs
      storageModel
      ;
  };
  inherit (model) cfg;
  baseUnits = [
    "user-runtime-dir@${toString model.uid}.service"
    "user@${toString model.uid}.service"
    "network-online.target"
  ];
  setupBefore = [
    "romm-web-assets.service"
    "mysql.service"
    "romm-db-init.service"
    "romm-valkey.service"
    "sops-install-secrets.service"
  ]
  ++ lib.optional cfg.backups.enable "romm-backup.service";
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
    (lib.getExe' cfg.toolsPackage "romm-run-setup")
    "--socket-url"
    model.podmanSocket
    "--config"
    setupConfig
    "--environment-file"
    config.sops.templates."romm.env".path
  ];
in
{
  config = lib.mkIf (cfg.enable && model.ready) {
    systemd.services.romm-setup = {
      description = "Run RomM database migrations and startup tasks";
      wantedBy = [ "multi-user.target" ];
      wants = baseUnits ++ setupBefore;
      requires = [ "romm-web-assets.service" ] ++ lib.optional cfg.backups.enable "romm-backup.service";
      after =
        baseUnits
        ++ setupBefore
        ++ [
          "systemd-tmpfiles-setup.service"
          "systemd-tmpfiles-resetup.service"
        ];
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      environment = {
        HOME = cfg.stateDir;
        XDG_RUNTIME_DIR = "/run/user/${toString model.uid}";
      };
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
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
