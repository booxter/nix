{
  config,
  hostInventory,
  pkgs,
  ...
}:
let
  aiService = hostInventory.servicesById.ai;
  litellmPort = 4000;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  openWebuiPort = 8082;
  searxPort = 18083;
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
    "litellm/master-key".restartUnits = [ "open-webui.service" ];
    "open-webui/admin/password" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "open-webui.service" ];
    };
    "open-webui/secret-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "open-webui.service" ];
    };
  };

  sops.templates."open-webui.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      OPENAI_API_KEY=${config.sops.placeholder."litellm/master-key"}
      WEBUI_ADMIN_PASSWORD=${config.sops.placeholder."open-webui/admin/password"}
      WEBUI_SECRET_KEY=${config.sops.placeholder."open-webui/secret-key"}
    '';
    restartUnits = [ "open-webui.service" ];
  };

  services.open-webui = {
    enable = true;
    host = "127.0.0.1";
    port = openWebuiPort;
    environmentFile = config.sops.templates."open-webui.env".path;
    environment = {
      DEFAULT_MODELS = "qwen3:8b";
      DEFAULT_PINNED_MODELS = "qwen3:8b";
      ENABLE_CODE_EXECUTION = "False";
      ENABLE_OLLAMA_API = "False";
      ENABLE_OPENAI_API = "True";
      ENABLE_WEB_SEARCH = "True";
      ENABLE_PERSISTENT_CONFIG = "False";
      ENABLE_SIGNUP = "False";
      OPENAI_API_BASE_URL = "http://127.0.0.1:${toString litellmPort}/v1";
      SEARXNG_LANGUAGE = "all";
      SEARXNG_QUERY_URL = "http://127.0.0.1:${toString searxPort}/search";
      TASK_MODEL_EXTERNAL = "qwen3:8b";
      WEB_LOADER_CONCURRENT_REQUESTS = "4";
      WEB_SEARCH_CONCURRENT_REQUESTS = "2";
      WEB_SEARCH_ENGINE = "searxng";
      WEB_SEARCH_RESULT_COUNT = "5";
      WEBUI_ADMIN_EMAIL = "ihar.hrachyshka@gmail.com";
      WEBUI_ADMIN_NAME = "Ihar";
      WEBUI_NAME = "Homelab AI";
      WEBUI_URL = aiService.url;
    };
  };

  systemd.services.open-webui = {
    wants = [
      "podman-litellm.service"
      "searx.service"
      "sops-install-secrets.service"
    ];
    after = [
      "podman-litellm.service"
      "searx.service"
      "sops-install-secrets.service"
    ];
  };

  services.searx = {
    enable = true;
    configureNginx = false;
    configureUwsgi = false;
    openFirewall = false;
    settings = {
      # This instance is loopback-only for Open WebUI. Use a SOPS-backed
      # secret_key before exposing SearXNG directly to users.
      server = {
        bind_address = "127.0.0.1";
        limiter = false;
        port = searxPort;
        public_instance = false;
        secret_key = "org-open-webui-local-searxng";
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

  host.internalHttps.services.ai = {
    enable = true;
    upstream = "http://127.0.0.1:${toString openWebuiPort}";
    serverAliases = [ aiService.publicHost ];
    mtls.enable = true;
    locationExtraConfig = ''
      client_max_body_size 128m;
      proxy_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };
}
