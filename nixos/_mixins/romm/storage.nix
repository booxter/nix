{
  lib,
  rommModel,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.${model.storageClaim} = {
      directories =
        builtins.listToAttrs (
          map
            (path: {
              name = "${model.storageRelativePath}/${path}";
              value.owner = model.user;
            })
            [
              "assets"
              "cache"
              "config"
              "library"
              "library/bios"
              "library/roms"
              "library/roms/pc"
              "resources"
              "sync"
            ]
        )
        // {
          ${model.storageRelativePath}.owner = model.user;
        };
      attachments.romm-setup = { };
    };
  };
}
