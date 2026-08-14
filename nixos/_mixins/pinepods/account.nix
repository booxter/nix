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
  inherit (model) cfg storageGroup user;
in
{
  config = lib.mkIf (cfg != null && storageGroup != null) {
    users.users.${user} = {
      isSystemUser = true;
      group = storageGroup;
      home = "/var/empty";
      uid = storageIdentities.users.${user}.uid;
    };
  };
}
