{
  lib,
  sabnzbdModel,
  ...
}:
let
  model = sabnzbdModel;
in
{
  config = lib.mkIf (model.cfg.enable && model.identity != null) {
    users.users.${model.cfg.user}.uid = model.identity.uid;
  };
}
