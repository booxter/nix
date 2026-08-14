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
      pkgs
      storageModel
      ;
  };
  inherit (model) cfg;
in
{
  config = lib.mkIf cfg.enable {
    host.storage.claims.${cfg.storage.claim} = {
      directories.${cfg.storage.relativePath} = {
        owner = cfg.user;
        mode = "0750";
      };
      attachments.podman-pinepods = { };
    };
  };
}
