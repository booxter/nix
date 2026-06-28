{
  config,
  hostInventory,
  pkgs,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  llmService = hostInventory.servicesById.llm;
  llmUrl = "https://${llmService.publicHost}";
  oidcClientId = "litellm";
  oidcIssuerBase = "https://${idService.publicHost}";
  oidcOpenidBase = "${oidcIssuerBase}/oauth2/openid/${oidcClientId}";
  ociImages = builtins.fromJSON (builtins.readFile ../../lib/oci-images.json);
  litellmImage = "${ociImages.litellm.image}:${ociImages.litellm.tag}";
  litellmDatabase = "litellm";
  litellmMetricsMtlsPort = 9346;
  litellmPort = 4000;
  litellmUser = "litellm";
  ollamaTunnelPort = 11435;
  litellmConfig = (pkgs.formats.yaml { }).generate "litellm-config.yaml" {
    model_list = [
      {
        model_name = "qwen3.5:9b";
        litellm_params = {
          model = "ollama_chat/qwen3.5:9b";
          api_base = "http://127.0.0.1:${toString ollamaTunnelPort}";
          keep_alive = "30m";
        };
        model_info = {
          mode = "chat";
          supports_function_calling = true;
          supports_vision = true;
          input_cost_per_token = 0.0;
          output_cost_per_token = 0.0;
        };
      }
      {
        model_name = "qwen3-next:80b";
        litellm_params = {
          model = "ollama_chat/qwen3-next:80b";
          api_base = "http://127.0.0.1:${toString ollamaTunnelPort}";
          keep_alive = "30m";
        };
        model_info = {
          mode = "chat";
          supports_function_calling = true;
          input_cost_per_token = 0.0;
          output_cost_per_token = 0.0;
        };
      }
      {
        model_name = "qwen3-vl:8b-instruct";
        litellm_params = {
          model = "ollama/qwen3-vl:8b-instruct";
          api_base = "http://127.0.0.1:${toString ollamaTunnelPort}";
          keep_alive = "30m";
        };
        model_info = {
          mode = "chat";
          supports_vision = true;
          input_cost_per_token = 0.0;
          output_cost_per_token = 0.0;
        };
      }
    ];
    general_settings = {
      database_url = "os.environ/DATABASE_URL";
      master_key = "os.environ/LITELLM_MASTER_KEY";
      ui_access_mode = "admin_only";
    };
    litellm_settings = {
      callbacks = [ "prometheus" ];
      drop_params = true;
      num_retries = 1;
      prometheus_metrics_config = [
        {
          group = "proxy_requests";
          metrics = [ "litellm_proxy_total_requests_metric" ];
          include_labels = [
            "requested_model"
            "status_code"
            "route"
          ];
        }
        {
          group = "proxy_requests";
          metrics = [ "litellm_proxy_failed_requests_metric" ];
          include_labels = [
            "requested_model"
            "route"
            "exception_status"
            "exception_class"
          ];
        }
        {
          group = "tokens";
          metrics = [
            "litellm_input_tokens_metric"
            "litellm_output_tokens_metric"
            "litellm_total_tokens_metric"
          ];
          include_labels = [
            "requested_model"
            "model"
          ];
        }
        {
          group = "latency";
          metrics = [
            "litellm_request_total_latency_metric"
            "litellm_llm_api_latency_metric"
            "litellm_llm_api_time_to_first_token_metric"
          ];
          include_labels = [
            "requested_model"
            "model"
          ];
        }
        {
          group = "proxy_health";
          metrics = [
            "litellm_in_flight_requests"
            "litellm_callback_logging_failures_metric"
          ];
        }
      ];
      require_auth_for_metrics_endpoint = false;
      request_timeout = 600;
    };
  };
in
{
  sops.secrets = {
    "litellm/database/password" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [
        "litellm-postgresql-password.service"
        "podman-litellm.service"
      ];
    };
    "litellm/master-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "podman-litellm.service" ];
    };
    "litellm/oidc/client_secret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "podman-litellm.service" ];
    };
  };

  sops.templates."litellm.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      DATABASE_URL=postgresql://${litellmUser}:${
        config.sops.placeholder."litellm/database/password"
      }@127.0.0.1:5432/${litellmDatabase}
      LITELLM_MASTER_KEY=${config.sops.placeholder."litellm/master-key"}
      GENERIC_CLIENT_ID=${oidcClientId}
      GENERIC_CLIENT_SECRET=${config.sops.placeholder."litellm/oidc/client_secret"}
      GENERIC_AUTHORIZATION_ENDPOINT=${oidcIssuerBase}/ui/oauth2
      GENERIC_TOKEN_ENDPOINT=${oidcIssuerBase}/oauth2/token
      GENERIC_USERINFO_ENDPOINT=${oidcOpenidBase}/userinfo
      GENERIC_SCOPE=openid email profile litellm_groups
      GENERIC_CLIENT_USE_PKCE=true
      GENERIC_USER_ID_ATTRIBUTE=preferred_username
      GENERIC_USER_EMAIL_ATTRIBUTE=email
      GENERIC_USER_DISPLAY_NAME_ATTRIBUTE=name
      GENERIC_ROLE_MAPPINGS_GROUP_CLAIM=litellm_groups
      GENERIC_ROLE_MAPPINGS_ROLES={'proxy_admin':['infra-admins']}
      PROXY_BASE_URL=${llmUrl}
    '';
    restartUnits = [ "podman-litellm.service" ];
  };

  services.postgresql = {
    ensureDatabases = [ litellmDatabase ];
    ensureUsers = [
      {
        name = litellmUser;
        ensureDBOwnership = true;
      }
    ];
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.litellm = {
      # The nixpkgs LiteLLM service currently starts without the Prisma binaries
      # needed for DB-backed proxy mode. Use the upstream database image until
      # the Nix package grows a complete Prisma runtime.
      image = litellmImage;
      pull = "missing";
      cmd = [
        "--host"
        "127.0.0.1"
        "--port"
        (toString litellmPort)
        "--config"
        "/app/config.yaml"
      ];
      environmentFiles = [ config.sops.templates."litellm.env".path ];
      extraOptions = [
        "--cap-drop=all"
        "--network=host"
        "--security-opt=no-new-privileges"
      ];
      volumes = [ "${litellmConfig}:/app/config.yaml:ro" ];
    };
  };

  systemd.services = {
    litellm-postgresql-password = {
      description = "Apply LiteLLM PostgreSQL password";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      after = [
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      before = [ "podman-litellm.service" ];
      path = [
        pkgs.postgresql
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        password="$(cat ${config.sops.secrets."litellm/database/password".path})"
        runuser -u postgres -- psql --set=ON_ERROR_STOP=1 --set=password="$password" <<'SQL'
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'litellm') THEN
            CREATE ROLE litellm LOGIN;
          END IF;
        END
        $$;
        ALTER ROLE litellm WITH LOGIN PASSWORD :'password';
        SQL
      '';
    };
    podman-litellm = {
      wants = [
        "litellm-postgresql-password.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      after = [
        "litellm-postgresql-password.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
    };
  };

  host.internalHttps.services.llm = {
    enable = true;
    upstream = "http://127.0.0.1:${toString litellmPort}";
    serverAliases = [ llmService.publicHost ];
    mtls.enable = true;
    locationExtraConfig = ''
      if ($uri = /metrics) {
        return 404;
      }
      proxy_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };

  host.observability.client.prometheusMtlsEndpoints.litellm = {
    enable = true;
    port = litellmMetricsMtlsPort;
    path = "/metrics/";
    upstream = "http://127.0.0.1:${toString litellmPort}/metrics/";
  };
}
