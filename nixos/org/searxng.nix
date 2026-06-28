{
  config,
  hostInventory,
  pkgs,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  searchService = hostInventory.servicesById.search;
  oauth2ClientId = "search";
  issuerUrl = "https://${idService.publicHost}/oauth2/openid/${oauth2ClientId}";
  oauth2ProxyCookieName = "_search_sso";
  oauth2ProxyUrl = config.services.oauth2-proxy.httpAddress;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  openWebuiDefaultModelMetadata = {
    # Enables Open WebUI's web-search feature by default for model chats.
    # Without this metadata, asking the model to search does not trigger the
    # SearXNG-backed retrieval path unless the user manually toggles search.
    capabilities.web_search = true;
    defaultFeatureIds = [ "web_search" ];
  };
  searxPort = 18083;
  authRequestLocationConfig = ''
    auth_request /oauth2/auth;
    error_page 401 = @search_oauth2_proxy_sign_in;

    auth_request_set $search_user $upstream_http_x_auth_request_user;
    auth_request_set $search_email $upstream_http_x_auth_request_email;
    auth_request_set $search_auth_cookie $upstream_http_set_cookie;

    proxy_set_header X-User $search_user;
    proxy_set_header X-Email $search_email;
    proxy_set_header Authorization "";
    add_header Set-Cookie $search_auth_cookie;
  '';
  oauth2ProxyLocations = {
    "/oauth2/" = {
      proxyPass = oauth2ProxyUrl;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Auth-Request-Redirect $scheme://$host$request_uri;
      '';
    };

    "= /oauth2/auth" = {
      proxyPass = "${oauth2ProxyUrl}/oauth2/auth";
      recommendedProxySettings = true;
      extraConfig = ''
        internal;
        auth_request off;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
      '';
    };

    "@search_oauth2_proxy_sign_in" = {
      return = "307 $scheme://$host/oauth2/start?rd=$scheme://$host$request_uri";
      extraConfig = ''
        auth_request off;
      '';
    };
  };
  searxProbeMetricsFile = "${nodeExporterTextfileDir}/open-webui-searxng.prom";
  searxProbeScript = pkgs.writeShellApplication {
    name = "open-webui-searxng-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      metrics_file="${searxProbeMetricsFile}"
      target_url="http://127.0.0.1:${toString searxPort}/search"

      metrics_dir="$(dirname "$metrics_file")"
      install -d -m 0755 "$metrics_dir"

      response_file="$(mktemp)"
      stderr_file="$(mktemp)"
      tmp_file="$(mktemp "$metrics_dir/.open-webui-searxng.prom.XXXXXX")"
      trap 'rm -f "$response_file" "$stderr_file" "$tmp_file"' EXIT

      now="$(date +%s)"
      ok=0
      http_status=0
      curl_exit=0
      duration=0
      result_count=0
      curl_output=""

      if curl_output="$(
        curl \
          --silent \
          --show-error \
          --get \
          --output "$response_file" \
          --write-out '%{http_code} %{time_total}' \
          --connect-timeout 5 \
          --max-time 30 \
          --data-urlencode 'q=prometheus' \
          --data 'format=json' \
          --data 'safesearch=1' \
          "$target_url" \
          2>"$stderr_file"
      )"; then
        http_status="''${curl_output%% *}"
        duration="''${curl_output#* }"

        if [ "$http_status" = "200" ] && jq -e '.results | type == "array"' "$response_file" >/dev/null; then
          ok=1
          result_count="$(jq '.results | length' "$response_file")"
        fi
      else
        curl_exit="$?"
      fi

      cat > "$tmp_file" <<EOF
      # HELP host_observability_openwebui_searxng_probe_ok Whether the most recent Open WebUI SearXNG dependency probe succeeded.
      # TYPE host_observability_openwebui_searxng_probe_ok gauge
      host_observability_openwebui_searxng_probe_ok $ok
      # HELP host_observability_openwebui_searxng_probe_timestamp_seconds Unix timestamp of the most recent Open WebUI SearXNG dependency probe.
      # TYPE host_observability_openwebui_searxng_probe_timestamp_seconds gauge
      host_observability_openwebui_searxng_probe_timestamp_seconds $now
      # HELP host_observability_openwebui_searxng_probe_duration_seconds Duration of the most recent Open WebUI SearXNG dependency probe.
      # TYPE host_observability_openwebui_searxng_probe_duration_seconds gauge
      host_observability_openwebui_searxng_probe_duration_seconds $duration
      # HELP host_observability_openwebui_searxng_probe_http_status_code HTTP status code returned by the most recent Open WebUI SearXNG dependency probe.
      # TYPE host_observability_openwebui_searxng_probe_http_status_code gauge
      host_observability_openwebui_searxng_probe_http_status_code $http_status
      # HELP host_observability_openwebui_searxng_probe_curl_exit_code Curl exit code from the most recent Open WebUI SearXNG dependency probe.
      # TYPE host_observability_openwebui_searxng_probe_curl_exit_code gauge
      host_observability_openwebui_searxng_probe_curl_exit_code $curl_exit
      # HELP host_observability_openwebui_searxng_probe_results Search result count returned by the most recent Open WebUI SearXNG dependency probe.
      # TYPE host_observability_openwebui_searxng_probe_results gauge
      host_observability_openwebui_searxng_probe_results $result_count
      EOF

      chmod 0644 "$tmp_file"
      mv "$tmp_file" "$metrics_file"
    '';
  };
in
{
  sops.secrets = {
    "searxng/secret_key" = {
      restartUnits = [
        "searx-init.service"
        "searx.service"
      ];
    };
    oauth2ProxySearchClientSecret = {
      key = "oauth2-proxy/search/client_secret";
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "oauth2-proxy.service" ];
    };
    oauth2ProxySearchCookieSecret = {
      key = "oauth2-proxy/search/cookie_secret";
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "oauth2-proxy.service" ];
    };
  };

  sops.templates."searxng.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      SEARX_SECRET_KEY=${config.sops.placeholder."searxng/secret_key"}
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
      server = {
        base_url = "${searchService.url}/";
        bind_address = "127.0.0.1";
        limiter = false;
        port = searxPort;
        public_instance = false;
        secret_key = "$SEARX_SECRET_KEY";
      };
      search = {
        formats = [
          "html"
          "json"
        ];
        safe_search = 1;
      };
    };
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = issuerUrl;
    clientID = oauth2ClientId;
    clientSecretFile = config.sops.secrets.oauth2ProxySearchClientSecret.path;
    approvalPrompt = "auto";
    cookie = {
      name = oauth2ProxyCookieName;
      secretFile = config.sops.secrets.oauth2ProxySearchCookieSecret.path;
    };
    email.domains = [ "*" ];
    scope = "openid email profile ai_groups";
    upstream = [ "static://202" ];
    reverseProxy = true;
    trustedProxyIP = [
      "127.0.0.1/32"
      "::1/128"
    ];
    setXauthrequest = true;
    passBasicAuth = false;
    extraConfig = {
      allowed-group = [ "ai-users" ];
      code-challenge-method = "S256";
      oidc-groups-claim = "ai_groups";
      skip-provider-button = true;
      whitelist-domain = [ searchService.publicHost ];
    };
  };

  host.internalHttps.services.search = {
    enable = true;
    upstream = "http://127.0.0.1:${toString searxPort}";
    serverAliases = [ searchService.publicHost ];
    mtls.enable = true;
    locationExtraConfig = authRequestLocationConfig;
  };

  services.nginx.virtualHosts."internal-https-search".locations = oauth2ProxyLocations;

  systemd.services.oauth2-proxy = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
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
      ExecStart = "${searxProbeScript}/bin/open-webui-searxng-probe";
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
