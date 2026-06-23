{
  config,
  hostInventory,
  pkgs,
  ...
}:
let
  llmService = hostInventory.servicesById.llm;
  litellmDatabase = "litellm";
  litellmPort = 4000;
  litellmUser = "litellm";
  ollamaTunnelPort = 11435;
in
{
  sops.secrets = {
    "litellm/database/password" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [
        "litellm-postgresql-password.service"
        "litellm.service"
      ];
    };
    "litellm/master-key" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "litellm.service" ];
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
    '';
    restartUnits = [ "litellm.service" ];
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

  services.litellm = {
    enable = true;
    host = "127.0.0.1";
    port = litellmPort;
    environmentFile = config.sops.templates."litellm.env".path;
    settings = {
      model_list = [
        {
          model_name = "qwen3:8b";
          litellm_params = {
            model = "ollama_chat/qwen3:8b";
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
          model_name = "minicpm-v:8b";
          litellm_params = {
            model = "ollama/minicpm-v:8b";
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
      };
      litellm_settings = {
        drop_params = true;
        num_retries = 1;
        request_timeout = 600;
      };
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
      before = [ "litellm.service" ];
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
    litellm = {
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
      proxy_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
  };
}
