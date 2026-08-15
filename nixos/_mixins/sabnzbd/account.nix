{
  lib,
  sabnzbdModel,
  ...
}:
let
  model = sabnzbdModel;
in
{
  config = lib.mkIf (model.cfg != null && model.identity != null) {
    users.users.sabnzbd.uid = model.identity.uid;
  };
}
