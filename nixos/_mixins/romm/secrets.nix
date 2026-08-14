{
  config,
  lib,
  pkgs,
  storageModel,
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
  inherit (model) cfg oidcClient;
  restartUnits = [
    "romm-db-init.service"
    "romm-setup.service"
    "podman-romm-api.service"
    "podman-romm-scheduler.service"
    "podman-romm-worker.service"
    "podman-romm-watcher.service"
  ];
in
{
  config = lib.mkIf (cfg.enable && model.ready) {
    sops.secrets = {
      "romm/authSecretKey" = { };
      "romm/dbPassword" = { };
    };

    sops.templates."romm.env" = {
      owner = cfg.user;
      group = model.storageGroup;
      mode = "0400";
      content = ''
        ROMM_AUTH_SECRET_KEY=${config.sops.placeholder."romm/authSecretKey"}
        DB_PASSWD=${config.sops.placeholder."romm/dbPassword"}
        OIDC_CLIENT_SECRET=${oidcClient.secret.placeholder}
      '';
      inherit restartUnits;
    };
  };
}
