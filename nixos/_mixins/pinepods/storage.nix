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
  inherit (model) cfg user;
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.media = {
      directories."podcasts/pinepods" = {
        owner = user;
        mode = "0750";
      };
      attachments.podman-pinepods = { };
    };
  };
}
