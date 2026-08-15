{
  config,
  lib,
  rommModel,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg oidcClient;
  restartUnits = [
    "romm-db-init.service"
    "romm-setup.service"
  ]
  ++ model.units.containers;
in
{
  config = lib.mkIf (cfg != null && model.ready) {
    sops.secrets = {
      "romm/authSecretKey" = { };
      "romm/dbPassword" = { };
    };

    sops.templates."romm.env" = {
      owner = model.user;
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
