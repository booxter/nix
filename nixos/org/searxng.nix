{
  config,
  hostInventory,
  ...
}:
let
  searchService = hostInventory.servicesById.search;
  oauth2ClientId = "search";
  oauth2ProxyCookieName = "_search_sso";
  searxMetricsMtlsPort = 9349;
  searxPort = 18083;
in
{
  sops.secrets = {
    "searxng/secret_key" = {
      restartUnits = [
        "searx-init.service"
        "searx.service"
      ];
    };
    "searxng/open_metrics_password" = {
      restartUnits = [
        "searx-init.service"
        "searx.service"
      ];
    };
  };

  sops.templates."searxng.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      SEARX_SECRET_KEY=${config.sops.placeholder."searxng/secret_key"}
      SEARX_OPEN_METRICS=${config.sops.placeholder."searxng/open_metrics_password"}
    '';
    restartUnits = [
      "searx-init.service"
      "searx.service"
    ];
  };

  services.searx = {
    enable = true;
    configureNginx = false;
    configureUwsgi = false;
    environmentFile = config.sops.templates."searxng.env".path;
    openFirewall = false;
    settings = {
      general = {
        enable_metrics = true;
        open_metrics = "$SEARX_OPEN_METRICS";
      };
      server = {
        base_url = "${searchService.url}/";
        bind_address = "127.0.0.1";
        image_proxy = true;
        limiter = false;
        port = searxPort;
        public_instance = false;
        secret_key = "$SEARX_SECRET_KEY";
      };
      preferences.lock = [ "image_proxy" ];
      search = {
        formats = [
          "html"
          "json"
        ];
        safe_search = 1;
      };
    };
  };

  systemd.services.searx-init = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  host.sso.oauth2ProxyGates.search = {
    enable = true;
    clientId = oauth2ClientId;
    cookieName = oauth2ProxyCookieName;
    allowedGroups = [
      "ai-users"
      "search-probe-users"
    ];
    groupClaim = "ai_groups";
    externalOrigin = searchService.url;
    whitelistDomains = [ searchService.publicHost ];
    internalHttpsServiceNames = [ "search" ];
    authCookieVariableName = "search_auth_cookie";
    authRequestHeaders = [
      {
        variableName = "search_user";
        upstreamHeader = "x_auth_request_user";
        proxyHeader = "X-User";
      }
      {
        variableName = "search_email";
        upstreamHeader = "x_auth_request_email";
        proxyHeader = "X-Email";
      }
    ];
    extraLocations."= /metrics" = {
      return = "404";
      extraConfig = ''
        auth_request off;
      '';
    };
    probeLocationsByName.search."= /healthz" = {
      proxyPass = "http://127.0.0.1:${toString searxPort}";
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };

  host.internalHttps.services.search = {
    enable = true;
    upstream = "http://127.0.0.1:${toString searxPort}";
    publicAliases = [ searchService.publicHost ];
    mtls.enable = true;
  };

  host.observability.client.prometheusMtlsEndpoints.searxng = {
    enable = true;
    port = searxMetricsMtlsPort;
    upstream = "http://127.0.0.1:${toString searxPort}/metrics";
  };

}
