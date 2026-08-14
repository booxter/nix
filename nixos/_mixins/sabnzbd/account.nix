{
  config,
  lib,
  storageModel,
  ...
}:
let
  model = import ./model.nix { inherit config lib storageModel; };
in
{
  config = lib.mkIf (model.cfg.enable && model.identity != null) {
    users.users.${model.cfg.user}.uid = model.identity.uid;
  };
}
