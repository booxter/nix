{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      pkgs
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
      uid = config.host.accounts.users.${cfg.user}.uid;
    };
  };
}
