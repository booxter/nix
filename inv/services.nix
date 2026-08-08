{
  llmProviderHost,
  publicDomain,
}:
{
  glanceCategories = [
    {
      id = "user";
      title = "User Apps";
    }
    {
      id = "media-admin";
      title = "Media Admin";
    }
    {
      id = "infrastructure";
      title = "Infrastructure";
    }
  ];

  definitions = [
    {
      id = "id";
      title = "SSO";
      icon = "sh:kanidm";
      instances.pki = { };
      publicHost = "id.${publicDomain}";
      probePath = "/status";
    }
    {
      id = "dash";
      title = "Dashboard";
      icon = "sh:glance";
      instances.srvarr = { };
      publicHost = "dash.${publicDomain}";
      probePath = "/";
    }
    {
      id = "glance";
      instances.srvarr = { };
      probePath = "/";
      blackboxProbe = false;
    }
    {
      id = "jellyfin";
      internalEndpointName = null;
      instances.beast = { };
      publicHost = "jf.${publicDomain}";
      probePath = "/web/";
      glanceCategory = "user";
    }
    {
      id = "lolek";
      instances.beast = { };
      probePath = "/metrics";
      internalEndpointName = null;
      blackboxProbe = false;
    }
    {
      id = "watchstate";
      title = "WatchState";
      icon = "sh:watchstate.png";
      instances.beast = { };
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/v1/api/system/healthcheck";
      glanceCategory = "media-admin";
    }
    {
      id = "seerr";
      instances.srvarr.dataDir = "/data/.state/nixarr/seerr";
      publicHost = "js.${publicDomain}";
      probePath = "/login";
      glanceCategory = "user";
    }
    {
      id = "romm";
      title = "RomM";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/romm";
        databaseDir = "/data/.state/nixarr/mysql";
        mediaDir = "/data/media";
      };
      publicHost = "game.${publicDomain}";
      probePath = "/api/heartbeat";
      glanceCategory = "user";
    }
    {
      id = "grafana";
      instances.fana = { };
      probePath = "/login";
      glanceCategory = "infrastructure";
    }
    {
      id = "prometheus";
      instances.fana = { };
      probePath = "/-/ready";
      internalEndpointName = null;
      blackboxProbe = false;
    }
    {
      id = "alertmanager";
      instances.fana = { };
      probePath = "/-/ready";
      blackboxProbe = false;
    }
    {
      id = "loki";
      instances.fana = { };
      probePath = "/ready";
      blackboxProbe = false;
    }
    {
      id = "home";
      title = "Home Assistant";
      icon = "sh:home-assistant";
      instances.home = { };
      probePath = "/";
      glanceCategory = "infrastructure";
    }
    {
      id = "houndarr";
      icon = "sh:houndarr.png";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/houndarr";
        requiresLocalServices = [
          "lidarr"
          "radarr"
          "sonarr"
        ];
      };
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health";
      glanceCategory = "media-admin";
    }
    {
      id = "radarr";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/radarr";
        mediaDir = "/data/media";
      };
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "sonarr";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/sonarr";
        mediaDir = "/data/media";
      };
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "lidarr";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/lidarr";
        mediaDir = "/data/media";
      };
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "letterboxd-list-radarr";
      title = "Letterboxd Radarr";
      instances.srvarr.requiresLocalServices = [ "radarr" ];
      probePath = "/";
    }
    {
      id = "aurral";
      instances.srvarr = { };
      publicHost = "mu.${publicDomain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health/live";
      glanceCategory = "user";
    }
    {
      id = "slskd";
      instances.srvarr.vpnConfinement = {
        profile = "airvpn";
        forwardedPort = {
          port = 13869;
          protocol = "tcp";
        };
      };
    }
    {
      id = "audiobookshelf";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/audiobookshelf";
        mediaDir = "/data/media";
      };
      publicHost = "au.${publicDomain}";
      probePath = "";
      glanceCategory = "user";
    }
    {
      id = "pinepods";
      title = "PinePods";
      icon = "https://raw.githubusercontent.com/madeofpendletonwool/PinePods/0.9.0/images/icon-192.png";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/pinepods";
        downloadsDir = "/data/media/podcasts/pinepods";
        mediaDir = "/data/media";
      };
      publicHost = "pod.${publicDomain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }
    {
      id = "shelfmark";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/shelfmark";
        mediaDir = "/data/media";
      };
      publicHost = "shelf.${publicDomain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }
    {
      id = "vikunja";
      instances.org = { };
      publicHost = "vi.${publicDomain}";
      probePath = "";
      glanceCategory = "user";
    }
    {
      id = "paperless";
      title = "Paperless";
      icon = "sh:paperless-ngx";
      instances.org = { };
      publicHost = "papers.${publicDomain}";
      probePath = "/accounts/login/";
      glanceCategory = "infrastructure";
    }
    {
      id = "paperless-gpt";
      title = "Paperless GPT";
      icon = "sh:paperless-ngx";
      instances.org = { };
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/version";
      glanceCategory = "infrastructure";
    }
    {
      id = "goo";
      title = "Degoog";
      icon = "https://raw.githubusercontent.com/degoog-org/degoog/0.23.0/src/public/images/degoog-logo.png";
      instances.org = { };
      publicHost = "goo.${publicDomain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/readyz";
      glanceCategory = "user";
    }
    {
      id = "ollama";
      title = "Ollama";
      instances.${llmProviderHost} = { };
      probePath = "/";
      blackboxProbe = false;
    }
    {
      id = "bazarr";
      instances.srvarr = {
        dataDir = "/data/.state/nixarr/bazarr";
        mediaDir = "/data/media";
      };
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/system/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "prowlarr";
      instances.srvarr.dataDir = "/data/.state/nixarr/prowlarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "transmission";
      instances.srvarr.vpnConfinement = {
        profile = "airvpn";
        forwardedPort = {
          port = 45486;
          protocol = "both";
        };
      };
      probePath = "/oauth2/sign_in";
      backendProbe = {
        path = "/__probe/transmission-rpc";
        blackboxModule = "http_service_409";
      };
      glanceCategory = "media-admin";
    }
    {
      id = "sabnzbd";
      title = "SABNZB";
      icon = "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg";
      instances.srvarr.vpnConfinement.profile = "airvpn";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/__probe/sabnzbd-version";
      glanceCategory = "media-admin";
    }
  ];
}
