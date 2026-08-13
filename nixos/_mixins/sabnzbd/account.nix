{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
in
{
  config = lib.mkIf (model.cfg.enable && model.account != null) {
    users.users.${model.cfg.user}.uid = model.account.uid;
  };
}
