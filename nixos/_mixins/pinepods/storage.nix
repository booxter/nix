{
  config,
  facts,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      facts
      lib
      outputs
      pkgs
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
      attachments.pinepods.unit = "podman-pinepods";
    };
  };
}
