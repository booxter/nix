{
  lib,
  sabnzbdModel,
  ...
}:
let
  model = sabnzbdModel;
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.media = {
      directories =
        builtins.listToAttrs (
          map
            (path: {
              name = "usenet/${path}";
              value = {
                owner = "sabnzbd";
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
          usenet = {
            owner = "sabnzbd";
            mode = "0755";
          };
          "usenet/.incomplete" = {
            owner = "sabnzbd";
            mode = "0755";
          };
        };
      attachments.sabnzbd = { };
    };
  };
}
