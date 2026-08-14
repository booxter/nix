{ config, lib, ... }:
let
  cfg = config.host.sabnzbd;
in
{
  config = lib.mkIf (cfg != null) {
    host.downloads.clients.sabnzbd = {
      kind = "usenet";
      implementation = "sabnzbd";
      endpoint = "http://127.0.0.1:6336";
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
