{
  config,
  hostInventory,
  lib,
  orgPkgs,
  pkgs,
  ...
}:
let
  chromaPort = 8100;
  litellmPort = 4000;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  ollamaTunnelPort = 11435;
  paperlessOpenWebuiGroup = "paperless-users";
  paperlessService = hostInventory.servicesById.paperless;
  paperlessToolServerId = "paperless-mcp-server";
  searchlessMetricsFile = "${nodeExporterTextfileDir}/searchless-ngx.prom";
  searchlessPort = 8001;
  searchlessMetricsScript = pkgs.writeShellApplication {
    name = "searchless-ngx-metrics";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      metrics_file="${searchlessMetricsFile}"
      base_url="http://127.0.0.1:${toString searchlessPort}"

      metrics_dir="$(dirname "$metrics_file")"
      install -d -m 0755 "$metrics_dir"

      health_file="$(mktemp)"
      test_file="$(mktemp)"
      sync_file="$(mktemp)"
      tmp_file="$(mktemp "$metrics_dir/.searchless-ngx.prom.XXXXXX")"
      trap 'rm -f "$health_file" "$test_file" "$sync_file" "$tmp_file"' EXIT

      get_json() {
        path="$1"
        output_file="$2"
        http_status=0

        if http_status="$(
          curl \
            --silent \
            --show-error \
            --output "$output_file" \
            --write-out '%{http_code}' \
            --connect-timeout 5 \
            --max-time 30 \
            "$base_url$path"
        )" && [ "$http_status" = "200" ] && jq -e 'type == "object"' "$output_file" >/dev/null; then
          return 0
        fi

        return 1
      }

      now="$(date +%s)"
      metrics_collection_success=0
      health_success=0
      test_connection_success=0
      sync_status_success=0
      paperless_connected=0
      vector_store_initialized=0
      paperless_documents=0
      chroma_chunks=0
      bulk_sync_limit=0

      if get_json "/health" "$health_file"; then
        health_success=1
      fi

      if get_json "/test-connection" "$test_file"; then
        test_connection_success=1
        paperless_connected="$(jq -r 'if .paperless_connected == true then 1 else 0 end' "$test_file")"
        vector_store_initialized="$(jq -r 'if .vector_store_initialized == true then 1 else 0 end' "$test_file")"
      fi

      if get_json "/sync/status" "$sync_file"; then
        sync_status_success=1
        paperless_documents="$(jq -r '(.paperless_documents // 0) | tonumber? // 0' "$sync_file")"
        chroma_chunks="$(jq -r '(.chroma_chunks // 0) | tonumber? // 0' "$sync_file")"
        bulk_sync_limit="$(jq -r '(.bulk_sync_limit // 0) | tonumber? // 0' "$sync_file")"
      fi

      if [ "$health_success" = "1" ] && [ "$test_connection_success" = "1" ] && [ "$sync_status_success" = "1" ]; then
        metrics_collection_success=1
      fi

      cat > "$tmp_file" <<EOF
      # HELP searchless_metrics_collection_success Whether the most recent Searchless API metrics collection completed successfully.
      # TYPE searchless_metrics_collection_success gauge
      searchless_metrics_collection_success $metrics_collection_success
      # HELP searchless_metrics_collection_timestamp_seconds Unix timestamp of the most recent Searchless API metrics collection.
      # TYPE searchless_metrics_collection_timestamp_seconds gauge
      searchless_metrics_collection_timestamp_seconds $now
      # HELP searchless_health_success Whether the most recent Searchless health endpoint probe succeeded.
      # TYPE searchless_health_success gauge
      searchless_health_success $health_success
      # HELP searchless_test_connection_success Whether the most recent Searchless test-connection API probe succeeded.
      # TYPE searchless_test_connection_success gauge
      searchless_test_connection_success $test_connection_success
      # HELP searchless_sync_status_success Whether the most recent Searchless sync status API probe succeeded.
      # TYPE searchless_sync_status_success gauge
      searchless_sync_status_success $sync_status_success
      # HELP searchless_paperless_connected Whether Searchless can query the Paperless API.
      # TYPE searchless_paperless_connected gauge
      searchless_paperless_connected $paperless_connected
      # HELP searchless_vector_store_initialized Whether Searchless can initialize the Chroma vector store.
      # TYPE searchless_vector_store_initialized gauge
      searchless_vector_store_initialized $vector_store_initialized
      # HELP searchless_paperless_documents Number of documents visible to Searchless in Paperless.
      # TYPE searchless_paperless_documents gauge
      searchless_paperless_documents $paperless_documents
      # HELP searchless_chroma_chunks Number of chunks stored in Chroma for Searchless retrieval.
      # TYPE searchless_chroma_chunks gauge
      searchless_chroma_chunks $chroma_chunks
      # HELP searchless_bulk_sync_limit Configured bulk sync document limit. Zero means unlimited.
      # TYPE searchless_bulk_sync_limit gauge
      searchless_bulk_sync_limit $bulk_sync_limit
      EOF

      chmod 0644 "$tmp_file"
      mv "$tmp_file" "$metrics_file"
    '';
  };
  searchlessStateDir = "/var/lib/searchless-ngx";
  searchlessUser = "searchless-ngx";

  toolServerConnections = [
    {
      type = "mcp";
      url = "http://127.0.0.1:${toString searchlessPort}/mcp";
      spec_type = "url";
      spec = "";
      path = "openapi.json";
      auth_type = "none";
      key = "";
      config = {
        enable = true;
        access_control = null;
        # The post-start reconciler resolves the SSO-managed group's Open WebUI
        # ID and replaces this fail-closed default at runtime.
        access_grants = [ ];
        function_name_filter_list = "";
      };
      info = {
        id = paperlessToolServerId;
        name = "Paperless MCP";
        description = "Searchless-ngx RAG tools for Paperless-ngx";
      };
    }
  ];
in
{
  users.groups.${searchlessUser} = { };
  users.users.${searchlessUser} = {
    isSystemUser = true;
    group = searchlessUser;
    home = searchlessStateDir;
  };

  sops.secrets = {
    "litellm/master-key".restartUnits = [ "searchless-ngx.service" ];
    "paperless/api/token".restartUnits = [ "searchless-ngx.service" ];
  };

  sops.templates."searchless-ngx.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      OPENAI_API_KEY=${config.sops.placeholder."litellm/master-key"}
      PAPERLESS_TOKEN=${config.sops.placeholder."paperless/api/token"}
    '';
    restartUnits = [ "searchless-ngx.service" ];
  };

  services.open-webui.environment.TOOL_SERVER_CONNECTIONS = builtins.toJSON toolServerConnections;

  systemd.services = {
    open-webui = {
      wants = [ "searchless-ngx.service" ];
      after = [ "searchless-ngx.service" ];
      postStart = ''
        OPEN_WEBUI_BASE_URL=http://127.0.0.1:${toString config.services.open-webui.port} \
        OPEN_WEBUI_ADMIN_EMAIL=${lib.escapeShellArg config.services.open-webui.environment.WEBUI_ADMIN_EMAIL} \
        OPEN_WEBUI_ACCESS_GROUP=${lib.escapeShellArg paperlessOpenWebuiGroup} \
        OPEN_WEBUI_TOOL_SERVER_ID=${lib.escapeShellArg paperlessToolServerId} \
          ${lib.getExe orgPkgs.open-webui-tool-acl-reconcile}
      '';
    };

    searchless-chroma = {
      description = "Chroma vector store for Searchless-ngx";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        ANONYMIZED_TELEMETRY = "False";
      };
      serviceConfig = {
        User = searchlessUser;
        Group = searchlessUser;
        StateDirectory = "searchless-ngx";
        StateDirectoryMode = "0750";
        WorkingDirectory = searchlessStateDir;
        ExecStart = "${pkgs.python313Packages.chromadb}/bin/chroma run --host 127.0.0.1 --port ${toString chromaPort} --path ${searchlessStateDir}/chroma";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ searchlessStateDir ];
      };
    };

    searchless-ngx = {
      description = "Searchless-ngx Paperless MCP server";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "paperless-web.service"
        "podman-litellm.service"
        "searchless-chroma.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      after = [
        "paperless-web.service"
        "podman-litellm.service"
        "searchless-chroma.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      environment = {
        CHROMA_HOST = "127.0.0.1";
        CHROMA_PORT = toString chromaPort;
        CHAT_MODEL = "granite4:32b-a9b-h";
        CHAT_PROVIDER = "openai";
        EMBEDDING_MODEL = "nomic-embed-text";
        EMBEDDING_PROVIDER = "ollama";
        LLM_PROVIDER = "openai";
        LOG_LEVEL = "INFO";
        MAX_CHUNKS_PER_DOC = "100";
        MCP_HOST = "127.0.0.1";
        MCP_PORT = toString searchlessPort;
        OLLAMA_BASE_URL = "http://127.0.0.1:${toString ollamaTunnelPort}/v1";
        OPENAI_BASE_URL = "http://127.0.0.1:${toString litellmPort}/v1";
        PAPERLESS_PUBLIC_URL = paperlessService.url;
        PAPERLESS_URL = "http://127.0.0.1:${toString config.services.paperless.port}";
        SYNC_INTERVAL_MINUTES = "15";
      };
      serviceConfig = {
        User = searchlessUser;
        Group = searchlessUser;
        EnvironmentFile = config.sops.templates."searchless-ngx.env".path;
        StateDirectory = "searchless-ngx";
        StateDirectoryMode = "0750";
        WorkingDirectory = searchlessStateDir;
        ExecStart = "${lib.getExe orgPkgs.searchless-ngx} --host 127.0.0.1 --port ${toString searchlessPort}";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ searchlessStateDir ];
      };
    };

    searchless-ngx-metrics = {
      description = "Collect Searchless-ngx API metrics for node exporter";
      wants = [ "searchless-ngx.service" ];
      after = [ "searchless-ngx.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe searchlessMetricsScript}";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ nodeExporterTextfileDir ];
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d ${nodeExporterTextfileDir} 0755 root root - -"
  ];

  systemd.timers.searchless-ngx-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "1m";
      AccuracySec = "15s";
    };
  };
}
