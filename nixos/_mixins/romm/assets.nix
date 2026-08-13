{
  config,
  facts,
  lib,
  outputs,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      facts
      lib
      outputs
      pkgs
      ;
  };
  inherit (model) cfg;
  userUnits = [
    "user-runtime-dir@${toString model.uid}.service"
    "user@${toString model.uid}.service"
  ];
  baseUnits = userUnits ++ [ "network-online.target" ];
  runtimeEnvironment = {
    HOME = cfg.stateDir;
    XDG_RUNTIME_DIR = "/run/user/${toString model.uid}";
  };
  command = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.toolsPackage "romm-prepare-assets")
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
  config = lib.mkIf (cfg.enable && model.ready) {
    systemd.services.romm-web-assets = {
      description = "Prepare RomM integration assets from upstream OCI image";
      wantedBy = [ "multi-user.target" ];
      wants = baseUnits;
      after = baseUnits ++ [
        "systemd-tmpfiles-setup.service"
        "systemd-tmpfiles-resetup.service"
      ];
      unitConfig.RequiresMountsFor = cfg.stateDir;
      environment = runtimeEnvironment;
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
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
