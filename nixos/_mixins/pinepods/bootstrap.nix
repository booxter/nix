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
  inherit (model) bootstrapOwner bootstrapOwnerName cfg;
  passwordSecret = "pinepods/bootstrap/password";
  command = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.package "pinepods-bootstrap-admin")
    "--url"
    "http://127.0.0.1:${toString cfg.port}"
    "--username"
    bootstrapOwnerName
    "--full-name"
    bootstrapOwner.displayName
    "--email-file"
    config.sops.secrets.${bootstrapOwner.mailAddressSopsKey}.path
    "--password-file"
    config.sops.secrets.${passwordSecret}.path
  ];
in
{
  config = lib.mkIf (cfg.enable && model.bootstrapReady) {
    sops.secrets = {
      ${passwordSecret} = {
        mode = "0400";
        restartUnits = [ "pinepods-bootstrap-admin.service" ];
      };
      ${bootstrapOwner.mailAddressSopsKey} = {
        mode = "0400";
        restartUnits = [ "pinepods-bootstrap-admin.service" ];
      };
    };

    systemd.services.pinepods-bootstrap-admin = {
      description = "Create the initial PinePods administrator";
      wantedBy = [ "multi-user.target" ];
      requires = [ "podman-pinepods.service" ];
      wants = [ "sops-install-secrets.service" ];
      after = [
        "podman-pinepods.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5min";
        ExecStart = command;
      };
    };
  };
}
