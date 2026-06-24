{
  config,
  hostInventory,
  ...
}:
let
  aiService = hostInventory.servicesById.ai;
  litellmPort = 4000;
  openWebuiPort = 8082;
  searxPort = 18083;
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
