{
  config,
  lib,
  storageModel,
  ...
}:
let
  model = import ./model.nix { inherit config lib storageModel; };
  inherit (model) cfg;
in
{
  config = lib.mkIf cfg.enable {
    host.sabnzbd.completeDir = model.completeDir;
    host.storage.claims.${cfg.storage.claim} = {
      directories =
        builtins.listToAttrs (
          map
            (path: {
              name = "${cfg.storage.relativePath}/${path}";
              value = {
                owner = cfg.user;
                mode = "0775";
              };
            })
            [
              "lidarr"
              "manual"
              "radarr"
              "sonarr"
              "watch"
            ]
        )
        // {
          ${cfg.storage.relativePath} = {
            owner = cfg.user;
            mode = "0755";
          };
          "${cfg.storage.relativePath}/.incomplete" = {
            owner = cfg.user;
            mode = "0755";
          };
        };
      attachments.sabnzbd = { };
    };
  };
}
