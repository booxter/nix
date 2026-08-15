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
    host.web.services.sabnzbd = {
      upstream = "http://127.0.0.1:${toString sabnzbdModel.port}";
      health = {
        frontend = {
          path = "/oauth2/sign_in";
        };
        backend = {
          path = "/__probe/sabnzbd-version";
          upstreamPath = "/api?mode=version&output=json";
          recommendedProxySettings = false;
          locationExtraConfig = ''
            proxy_set_header Host ${config.networking.hostName};
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Server $hostname;
          '';
        };
      };
      displayName = "SABnzbd";
      dashboard = {
        section = "media-admin";
      };
      auth.policy = "media-admin";
    };
  };
}
