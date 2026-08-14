{
  config,
  lib,
  pkgs,
  storageIdentities,
  storageModel,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      pkgs
      storageModel
      ;
  };
  inherit (model) cfg storageGroup;
in
{
  config = lib.mkIf (cfg.enable && storageGroup != null) {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = storageGroup;
      home = "/var/empty";
      uid = storageIdentities.users.${cfg.user}.uid;
    };
  };
}
