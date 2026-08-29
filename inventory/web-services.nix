{
  beast = {
    atticd = {
      declaration = {
        internal.serverName = "attic.home.arpa";
        observability.importance = "important";
      };
    };
    jellyfin = {
      declaration = {
        upstream = "http://127.0.0.1:8096";
        internal = null;
        public = {
          hostName = "jf.ihar.dev";
          routes.originalDownloads = {
            location = "~* ^/Items/[^/]+/Download/?$";
            bandwidthLimit = {
              listenPort = 18096;
              bytesPerSecond = 5 * 1000 * 1000 / 8;
              unlimitedCidrs = [
                "127.0.0.0/8"
                "::1"
                "192.168.0.0/16"
                "fe80::/10"
                "fc00::/7"
              ];
            };
          };
        };
        health.frontend.path = "/web/";
        metrics.default = {
          port = 9594;
          scrapeInterval = "5s";
        };
        observability.importance = "important";
        dashboard.section = "user";
      };
    };
    watchstate = {
      declaration = {
        displayName = "WatchState";
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/v1/api/system/healthcheck";
        };
        dashboard = {
          icon = "sh:watchstate.png";
          section = "media-admin";
        };
      };
    };
  };
  fana = {
    alertmanager = {
      declaration.internal.clientAuth = "mtls";
    };
    grafana = {
      declaration = {
        health.frontend.path = "/login";
        dashboard.section = "infrastructure";
      };
    };
    loki = {
      declaration.internal.clientAuth = "mtls";
    };
  };
  frame = {
    ollama = {
      declaration.internal.clientAuth = "mtls";
    };
  };
  home = {
    home = {
      declaration = {
        displayName = "Home Assistant";
        health.frontend = { };
        metrics.default = {
          endpointName = "home-assistant";
          jobName = "home-assistant";
          port = 9346;
        };
        dashboard = {
          icon = "sh:home-assistant";
          section = "infrastructure";
        };
      };
    };
  };
  org = {
    goo = {
      declaration = {
        displayName = "Degoog";
        public.hostName = "goo.ihar.dev";
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/readyz";
        };
        observability.importance = "best-effort";
        dashboard = {
          icon = "https://raw.githubusercontent.com/degoog-org/degoog/0.23.0/src/public/images/degoog-logo.png";
          section = "user";
        };
      };
    };
    paperless = {
      declaration = {
        public = {
          hostName = "papers.ihar.dev";
          locationExtraConfig = ''
            client_max_body_size 512m;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
          '';
        };
        health.frontend.path = "/accounts/login/";
        metrics.default = {
          port = 9348;
        };
        dashboard = {
          icon = "sh:paperless-ngx";
          section = "infrastructure";
        };
      };
    };
    paperless-gpt = {
      declaration = {
        displayName = "Paperless GPT";
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/api/version";
        };
        dashboard = {
          icon = "sh:paperless-ngx";
          section = "infrastructure";
        };
      };
    };
    vikunja = {
      declaration = {
        displayName = "Vikunja";
        public.hostName = "vi.ihar.dev";
        health.frontend.path = "";
        metrics.default = {
          port = 9345;
        };
        dashboard.section = "user";
      };
    };
  };
  pki = {
    id = {
      declaration = {
        displayName = "SSO";
        public.hostName = "id.ihar.dev";
        health.frontend.path = "/status";
        observability = {
          importance = "critical";
          externalProbe.requirement = "required";
        };
      };
    };
  };
  prx1-lab = {
    proxmox-prx1-lab = {
      declaration = {
        displayName = "Proxmox VE";
        internal.serverName = "proxmox.home.arpa";
        health.frontend = { };
        dashboard = {
          id = "proxmox-lab";
          icon = "sh:proxmox";
          section = "infrastructure";
        };
        metrics.default = {
          discover = false;
          endpointName = "pve";
          jobName = "pve";
          path = "/";
          port = 9221;
        };
      };
    };
  };
  prx2-lab = {
    proxmox-prx2-lab = {
      declaration = {
        displayName = "Proxmox prx2-lab";
        internal.serverName = "prx2-lab";
        health.frontend = { };
        metrics.default = {
          discover = false;
          endpointName = "pve";
          jobName = "pve";
          path = "/";
          port = 9221;
        };
      };
    };
  };
  prx3-lab = {
    proxmox-prx3-lab = {
      declaration = {
        displayName = "Proxmox prx3-lab";
        internal.serverName = "prx3-lab";
        health.frontend = { };
        metrics.default = {
          discover = false;
          endpointName = "pve";
          jobName = "pve";
          path = "/";
          port = 9221;
        };
      };
    };
  };
  srvarr = {
    audiobookshelf = {
      declaration = {
        public.hostName = "au.ihar.dev";
        health.frontend.path = "";
        observability.importance = "important";
        dashboard.section = "user";
      };
    };
    aurral = {
      declaration = {
        public = {
          hostName = "mu.ihar.dev";
          locationExtraConfig = ''
            proxy_set_header X-Forwarded-For $remote_addr;
          '';
        };
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/api/health/live";
        };
        observability.importance = "important";
        dashboard.section = "user";
      };
    };
    bazarr = {
      declaration = {
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/api/system/ping";
        };
        dashboard.section = "media-admin";
      };
    };
    dash = {
      declaration = {
        displayName = "Dashboard";
        public = {
          hostName = "dash.ihar.dev";
          serveOnOwner = false;
          splitDnsHost = "srvarr";
        };
        health.frontend = { };
        observability = {
          importance = "critical";
          externalProbe.requirement = "required";
        };
      };
    };
    glance = {
      declaration = { };
    };
    houndarr = {
      declaration = {
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/api/health";
        };
        dashboard = {
          icon = "sh:houndarr.png";
          section = "media-admin";
        };
      };
    };
    letterboxd-list-radarr = {
      declaration = {
        displayName = "Letterboxd Radarr";
        health.frontend = { };
      };
    };
    lidarr = {
      declaration = {
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/ping";
        };
        dashboard.section = "media-admin";
      };
    };
    pinepods = {
      declaration = {
        displayName = "PinePods";
        public.hostName = "pod.ihar.dev";
        health = {
          frontend.path = "/api/health";
          backend.path = "/api/health";
        };
        observability.importance = "best-effort";
        dashboard.section = "user";
      };
    };
    prowlarr = {
      declaration = {
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/ping";
        };
        dashboard.section = "media-admin";
      };
    };
    radarr = {
      declaration = {
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/ping";
        };
        dashboard.section = "media-admin";
      };
    };
    romm = {
      declaration = {
        displayName = "RomM";
        public.hostName = "game.ihar.dev";
        health.frontend.path = "/api/heartbeat";
        dashboard.section = "user";
      };
    };
    sabnzbd = {
      declaration = {
        displayName = "SABnzbd";
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/__probe/sabnzbd-version";
        };
        metrics.default = {
          port = 9387;
        };
        dashboard.section = "media-admin";
      };
    };
    seerr = {
      declaration = {
        public.hostName = "js.ihar.dev";
        health.frontend.path = "/login";
        observability.importance = "important";
        dashboard.section = "user";
      };
    };
    shelfmark = {
      declaration = {
        internal.serverName = "shelfmark.home.arpa";
        public.hostName = "shelf.ihar.dev";
        health.frontend.path = "/api/health";
        observability.importance = "important";
        dashboard.section = "user";
      };
    };
    sonarr = {
      declaration = {
        health = {
          frontend.path = "/oauth2/sign_in";
          backend.path = "/ping";
        };
        dashboard.section = "media-admin";
      };
    };
    transmission = {
      declaration = {
        health = {
          frontend.path = "/oauth2/sign_in";
          backend = {
            path = "/__probe/transmission-rpc";
            module = "http_service_409";
          };
        };
        dashboard.section = "media-admin";
      };
    };
  };
}
