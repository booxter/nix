{ publicDomain }:
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
      owner = "pki";
      publicHost = "id.${publicDomain}";
      probePath = "/status";
    }
    {
      id = "dash";
      title = "Dashboard";
      icon = "sh:glance";
      owner = "srvarr";
      publicHost = "dash.${publicDomain}";
      probePath = "/";
    }
    {
      id = "glance";
      owner = "srvarr";
      probePath = "/";
      blackboxProbe = false;
    }
    {
      id = "jellyfin";
      internalEndpointName = null;
      owner = "beast";
      publicHost = "jf.${publicDomain}";
      probePath = "/web/";
      glanceCategory = "user";
    }
    {
      id = "watchstate";
      title = "WatchState";
      icon = "sh:watchstate.png";
      owner = "beast";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/v1/api/system/healthcheck";
      glanceCategory = "media-admin";
    }
    {
      id = "seerr";
      owner = "srvarr";
      publicHost = "js.${publicDomain}";
      probePath = "/login";
      glanceCategory = "user";
    }
    {
      id = "romm";
      title = "RomM";
      owner = "srvarr";
      publicHost = "game.${publicDomain}";
      probePath = "/api/heartbeat";
      glanceCategory = "user";
    }
    {
      id = "grafana";
      owner = "fana";
      probePath = "/login";
      glanceCategory = "infrastructure";
    }
    {
      id = "alertmanager";
      owner = "fana";
      probePath = "/-/ready";
      blackboxProbe = false;
    }
    {
      id = "loki";
      owner = "fana";
      probePath = "/ready";
      blackboxProbe = false;
    }
    {
      id = "home";
      title = "Home Assistant";
      icon = "sh:home-assistant";
      owner = "home";
      probePath = "/";
      glanceCategory = "infrastructure";
    }
    {
      id = "houndarr";
      icon = "sh:houndarr.png";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health";
      glanceCategory = "media-admin";
    }
    {
      id = "radarr";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "sonarr";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "lidarr";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "letterboxd-list-radarr";
      title = "Letterboxd Radarr";
      owner = "srvarr";
      probePath = "/";
    }
    {
      id = "aurral";
      owner = "srvarr";
      publicHost = "mu.${publicDomain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health/live";
      glanceCategory = "user";
    }
    {
      id = "audiobookshelf";
      owner = "srvarr";
      publicHost = "au.${publicDomain}";
      probePath = "";
      glanceCategory = "user";
    }
    {
      id = "pinepods";
      title = "PinePods";
      icon = "https://raw.githubusercontent.com/madeofpendletonwool/PinePods/0.9.0/images/icon-192.png";
      owner = "srvarr";
      publicHost = "pod.${publicDomain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }
    {
      id = "shelfmark";
      owner = "srvarr";
      publicHost = "shelf.${publicDomain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }
    {
      id = "vikunja";
      owner = "org";
      publicHost = "vi.${publicDomain}";
      probePath = "";
      glanceCategory = "user";
    }
    {
      id = "notes";
      title = "Trilium Notes";
      icon = "sh:trilium-notes";
      owner = "org";
      publicHost = "notes.${publicDomain}";
      probePath = "/authenticate";
      backendProbe.path = "/api/health-check";
      glanceCategory = "infrastructure";
    }
    {
      id = "paperless";
      title = "Paperless";
      icon = "sh:paperless-ngx";
      owner = "org";
      publicHost = "papers.${publicDomain}";
      probePath = "/accounts/login/";
      glanceCategory = "infrastructure";
    }
    {
      id = "paperless-gpt";
      title = "Paperless GPT";
      icon = "sh:paperless-ngx";
      owner = "org";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/version";
      glanceCategory = "infrastructure";
    }
    {
      id = "llm";
      title = "LLM Gateway";
      icon = "sh:litellm";
      owner = "org";
      publicHost = "llm.${publicDomain}";
      probePath = "/health/liveliness";
      glanceCategory = "infrastructure";
    }
    {
      id = "search";
      title = "Search";
      icon = "sh:searxng";
      owner = "org";
      publicHost = "search.${publicDomain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/healthz";
      glanceCategory = "user";
    }
    {
      id = "goo";
      title = "Degoog";
      icon = "https://raw.githubusercontent.com/degoog-org/degoog/0.23.0/src/public/images/degoog-logo.png";
      owner = "org";
      publicHost = "goo.${publicDomain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/readyz";
      glanceCategory = "user";
    }
    {
      id = "ollama";
      title = "Ollama";
      owner = "frame";
      probePath = "/";
      blackboxProbe = false;
    }
    {
      id = "bazarr";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/system/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "prowlarr";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "transmission";
      owner = "srvarr";
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
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/__probe/sabnzbd-version";
      glanceCategory = "media-admin";
    }
  ];
}
