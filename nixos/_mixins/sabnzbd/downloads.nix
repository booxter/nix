{ config, lib, ... }:
let
  cfg = config.host.sabnzbd;
in
{
  config = lib.mkIf cfg.enable {
    host.downloads.clients.sabnzbd = {
      kind = "usenet";
      implementation = "sabnzbd";
      endpoint = "http://127.0.0.1:${toString cfg.port}";
      authentication = {
        type = "api-key";
        secret = cfg.secrets.apiKey;
      };
      storageDefaults = {
        owner = cfg.user;
        group = cfg.group;
        mode = "0775";
      };
    };
  };
}
