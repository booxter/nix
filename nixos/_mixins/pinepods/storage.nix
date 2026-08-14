{
  lib,
  pinepodsModel,
  storageIdentities,
  ...
}:
let
  inherit (pinepodsModel) cfg storageGroup user;
in
{
  config = lib.mkIf (cfg != null) {
    users.users.${user} = lib.mkIf (storageGroup != null) {
      isSystemUser = true;
      group = storageGroup;
      home = "/var/empty";
      uid = storageIdentities.users.${user}.uid;
    };

    host.storage.claims.media = {
      directories."podcasts/pinepods" = {
        owner = user;
        mode = "0750";
      };
      attachments.podman-pinepods = { };
    };
  };
}
