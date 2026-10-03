{
  config,
  lib,
  sabnzbdModel,
  ...
}:
let
  cfg = config.host.sabnzbd;
in
{
  config = lib.mkIf (cfg != null) {
    host.downloads.clients.sabnzbd = {
      kind = "usenet";
      implementation = "sabnzbd";
      endpoint = "http://127.0.0.1:${toString sabnzbdModel.port}";
      authentication = {
        type = "api-key";
        secret = "sabnzbd/apiKey";
      };
      storageDefaults = {
        owner = "sabnzbd";
        group = "media";
        mode = "0775";
      };
    };
  };
}
