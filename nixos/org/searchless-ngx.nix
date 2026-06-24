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
  ollamaTunnelPort = 11435;
  paperlessService = hostInventory.servicesById.paperless;
  searchlessPort = 8001;
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
        access_grants = [
          {
            principal_type = "user";
            principal_id = "*";
            permission = "read";
          }
        ];
        function_name_filter_list = "";
      };
      info = {
        id = "paperless-mcp-server";
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
        EMBEDDING_MODEL = "nomic-embed-text";
        EMBEDDING_PROVIDER = "ollama";
        LLM_MODEL = "qwen3.5:9b";
        LLM_PROVIDER = "litellm";
        LOG_LEVEL = "INFO";
        MAX_CHUNKS_PER_DOC = "100";
        MCP_HOST = "127.0.0.1";
        MCP_PORT = toString searchlessPort;
        OLLAMA_BASE_URL = "http://127.0.0.1:${toString ollamaTunnelPort}";
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
  };
}
