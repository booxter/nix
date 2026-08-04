{
  config,
  hostInventory,
  lib,
  orgPkgs,
  utils,
  ...
}:
let
  searchService = hostInventory.servicesById.search;
  oauth2ClientId = "search";
  oauth2ProxyCookieName = "_search_sso";
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  openWebuiDefaultModelMetadata = {
    # Enables Open WebUI's web-search feature by default for model chats.
    # Without this metadata, asking the model to search does not trigger the
    # SearXNG-backed retrieval path unless the user manually toggles search.
    capabilities.web_search = true;
    defaultFeatureIds = [ "web_search" ];
    builtinTools = {
      automations = false;
      calendar = false;
      knowledge = false;
    };
  };
  searxMetricsMtlsPort = 9349;
  searxPort = 18083;
  searxProbeMetricsFile = "${nodeExporterTextfileDir}/open-webui-searxng.prom";
  searxProbeCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' orgPkgs.search-stack-probes "open-webui-searxng-probe")
    "--url"
    "http://127.0.0.1:${toString searxPort}/search"
    "--metrics-file"
    searxProbeMetricsFile
  ];
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

  services.open-webui.environment = {
    DEFAULT_MODEL_METADATA = builtins.toJSON openWebuiDefaultModelMetadata;
    ENABLE_WEB_SEARCH = "True";
    SEARXNG_LANGUAGE = "all";
    SEARXNG_QUERY_URL = "http://127.0.0.1:${toString searxPort}/search";
    WEB_SEARCH_CONCURRENT_REQUESTS = "2";
    WEB_SEARCH_ENGINE = "searxng";
    WEB_SEARCH_RESULT_COUNT = "5";
  };

  systemd.services.open-webui = {
    wants = [ "searx.service" ];
    after = [ "searx.service" ];
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

  systemd.tmpfiles.rules = [
    "d ${nodeExporterTextfileDir} 0755 root root - -"
  ];

  systemd.services.open-webui-searxng-probe = {
    description = "Probe Open WebUI SearXNG search dependency";
    wants = [ "searx.service" ];
    after = [ "searx.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = searxProbeCommand;
    };
  };

  systemd.timers.open-webui-searxng-probe = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "5m";
      AccuracySec = "30s";
    };
  };
}
