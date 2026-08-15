{
  lib,
  transmissionModel,
  ...
}:
let
  model = transmissionModel;
  inherit (model) cfg;
  relativePath = cfg.storage.relativePath;
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.${cfg.storage.claim} = {
      directories =
        builtins.listToAttrs (
          map
            (path: {
              name = "${relativePath}/${path}";
              value = {
                owner = model.user;
                mode = "0755";
              };
            })
            [
              ".incomplete"
              ".watch"
              "lidarr"
              "manual"
              "radarr"
              "sonarr"
            ]
        )
        // {
          ${relativePath} = {
            owner = model.user;
            mode = "0755";
          };
        };
      attachments.transmission = { };
    };
  };
}
