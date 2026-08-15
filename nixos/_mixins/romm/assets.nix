{
  lib,
  rommModel,
  utils,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg;
  baseUnits = model.units.user ++ [ "network-online.target" ];
  command = utils.escapeSystemdExecArgs [
    (lib.getExe' model.toolsPackage "romm-prepare-assets")
    "--socket-url"
    model.podmanSocket
    "--image-ref"
    model.image
    "--image-file"
    model.imageFile
    "--state-dir"
    cfg.stateDir
  ];
in
{
  config = lib.mkIf (cfg != null && model.ready) {
    systemd.services.romm-web-assets = {
      description = "Prepare RomM integration assets from upstream OCI image";
      wantedBy = [ "multi-user.target" ];
      wants = baseUnits;
      after = baseUnits ++ model.units.tmpfiles;
      unitConfig.RequiresMountsFor = cfg.stateDir;
      environment = model.runtimeEnvironment;
      serviceConfig = {
        Type = "oneshot";
        User = model.user;
        Group = model.storageGroup;
        WorkingDirectory = cfg.stateDir;
        UMask = "0027";
        RemainAfterExit = true;
        ExecStart = command;
        TimeoutStartSec = "10min";
      };
    };
  };
}
