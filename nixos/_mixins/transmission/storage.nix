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
  config = lib.mkIf cfg.enable {
    host.transmission = {
      inherit (model)
        completeDir
        incompleteDir
        rpcPort
        rpcUrl
        watchDir
        ;
    };

    host.storage.claims.${cfg.storage.claim} = {
      directories =
        builtins.listToAttrs (
          map
            (path: {
              name = "${relativePath}/${path}";
              value = {
                owner = cfg.user;
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
            owner = cfg.user;
            mode = "0755";
          };
        };
      attachments.transmission = { };
    };
  };
}
