{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  aiService = hostInventory.servicesById.ai;
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  litellmPort = 4000;
  oidcClientId = oidc.clients."open-webui".clientId;
  oidcDiscoveryUrl = oidc.discoveryUrl oidcClientId;
  oidcRedirectUri = "${aiService.url}/oauth/oidc/login/callback";
  openWebuiMetricsMtlsPort = 9347;
  openWebuiOtelGrpcPort = 4317;
  openWebuiPrometheusPort = 9464;
  openWebuiPort = 8082;
  openWebuiPackage = pkgs.open-webui.overridePythonAttrs (oldAttrs: {
    dependencies = oldAttrs.dependencies ++ [
      # TODO: Drop this override after nixpkgs includes Open WebUI's OTEL
      # system metrics instrumentation runtime dependency upstream.
      pkgs.python313Packages.opentelemetry-instrumentation-system-metrics
    ];
  });
  openWebuiDefaultModelParams = {
    function_calling = "native";
    system = ''
      Current date and time: {{CURRENT_DATETIME}} ({{CURRENT_WEEKDAY}}).
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
    "open-webui/oidc/client_secret" = {
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
      OAUTH_CLIENT_SECRET=${config.sops.placeholder."open-webui/oidc/client_secret"}
      WEBUI_ADMIN_PASSWORD=${config.sops.placeholder."open-webui/admin/password"}
      WEBUI_SECRET_KEY=${config.sops.placeholder."open-webui/secret-key"}
    '';
    restartUnits = [ "open-webui.service" ];
  };

  services.open-webui = {
    enable = true;
    package = openWebuiPackage;
    host = "127.0.0.1";
    port = openWebuiPort;
    environmentFile = config.sops.templates."open-webui.env".path;
    environment = {
      DEFAULT_MODELS = "qwen3-next:80b";
      DEFAULT_PINNED_MODELS = "qwen3-next:80b,gemma4:31b,granite4:32b-a9b-h,nemotron-cascade-2:30b";
      ENABLE_CODE_EXECUTION = "False";
      ENABLE_LOGIN_FORM = "False";
      ENABLE_OTEL = "True";
      ENABLE_OTEL_LOGS = "False";
      ENABLE_OTEL_METRICS = "True";
      ENABLE_OTEL_TRACES = "False";
      ENABLE_OLLAMA_API = "False";
      ENABLE_OPENAI_API = "True";
      ENABLE_OAUTH_GROUP_CREATION = "True";
      ENABLE_OAUTH_GROUP_MANAGEMENT = "True";
      ENABLE_OAUTH_PERSISTENT_CONFIG = "False";
      ENABLE_OAUTH_ROLE_MANAGEMENT = "True";
      ENABLE_OAUTH_SIGNUP = "True";
      ENABLE_PERSISTENT_CONFIG = "False";
      ENABLE_SIGNUP = "False";
      OAUTH_AUTO_REDIRECT = "True";
      OAUTH_ADMIN_ROLES = "admin";
      OAUTH_ALLOWED_ROLES = "user";
      OAUTH_CLIENT_ID = oidcClientId;
      OAUTH_CODE_CHALLENGE_METHOD = "S256";
      OAUTH_GROUP_CLAIM = "open_webui_groups";
      OAUTH_GROUP_DEFAULT_SHARE = "False";
      OAUTH_MERGE_ACCOUNTS_BY_EMAIL = "True";
      OAUTH_PROVIDER_NAME = "SSO";
      OAUTH_ROLES_CLAIM = "open_webui_role";
      OAUTH_SCOPES = lib.concatStringsSep " " (oidc.scopeWith [ "open_webui_groups" ]);
      OAUTH_TOKEN_ENDPOINT_AUTH_METHOD = "client_secret_basic";
      OTEL_METRICS_EXPORT_INTERVAL_MILLIS = "10000";
      OTEL_METRICS_EXPORTER_OTLP_ENDPOINT = "http://127.0.0.1:${toString openWebuiOtelGrpcPort}";
      OTEL_METRICS_EXPORTER_OTLP_INSECURE = "True";
      OTEL_METRICS_OTLP_SPAN_EXPORTER = "grpc";
      OTEL_SERVICE_NAME = "open-webui";
      OPENAI_API_BASE_URL = "http://127.0.0.1:${toString litellmPort}/v1";
      OPENID_PROVIDER_URL = oidcDiscoveryUrl;
      OPENID_REDIRECT_URI = oidcRedirectUri;
      DEFAULT_MODEL_PARAMS = builtins.toJSON openWebuiDefaultModelParams;
      TASK_MODEL_EXTERNAL = "granite4:32b-a9b-h";
      WEB_LOADER_CONCURRENT_REQUESTS = "4";
      WEBUI_ADMIN_EMAIL = "ihar.hrachyshka@gmail.com";
      WEBUI_ADMIN_NAME = "Ihar";
      WEBUI_NAME = "Homelab AI";
      WEBUI_URL = aiService.url;
    };
  };

  services.opentelemetry-collector = {
    enable = true;
    package = pkgs.opentelemetry-collector-contrib;
    validateConfigFile = true;
    settings = {
      receivers.otlp.protocols.grpc.endpoint = "127.0.0.1:${toString openWebuiOtelGrpcPort}";
      exporters.prometheus = {
        endpoint = "127.0.0.1:${toString openWebuiPrometheusPort}";
        namespace = "open_webui";
        resource_to_telemetry_conversion.enabled = true;
      };
      service.pipelines.metrics = {
        receivers = [ "otlp" ];
        exporters = [ "prometheus" ];
      };
    };
  };

  systemd.services.open-webui = {
    wants = [
      "opentelemetry-collector.service"
      "podman-litellm.service"
      "sops-install-secrets.service"
    ];
    after = [
      "opentelemetry-collector.service"
      "podman-litellm.service"
      "sops-install-secrets.service"
    ];
  };

  host.internalHttps.services.ai = {
    enable = true;
    upstream = "http://127.0.0.1:${toString openWebuiPort}";
    publicAliases = [ aiService.publicHost ];
    mtls.enable = true;
    locationExtraConfig = ''
      client_max_body_size 128m;
      proxy_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };

  host.observability.client.prometheusMtlsEndpoints."open-webui" = {
    enable = true;
    port = openWebuiMetricsMtlsPort;
    upstream = "http://127.0.0.1:${toString openWebuiPrometheusPort}/metrics";
  };
}
