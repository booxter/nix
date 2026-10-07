{
  config,
  lib,
  rommModel,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg state storageGroup;
in
{
  config = lib.mkIf (cfg != null && model.ready) {
    users.users = {
      ${model.user} = {
        isSystemUser = true;
        group = storageGroup;
        uid = model.uid;
      };
      ${config.services.nginx.user}.extraGroups = [ storageGroup ];
    };

    systemd.tmpfiles.rules = map (path: "d '${path}' 0750 ${model.user} ${storageGroup} - -") [
      cfg.stateDir
      state.valkeyDir
    ];
  };
}
