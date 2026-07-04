{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  ociImages = import ../../lib/oci-images.nix { inherit pkgs; };
  jellystatImage = ociImages.jellystat.ref;
  jellystatImageFile = ociImages.jellystat.imageFile;
  jellystatHostName = "jfstat.${hostInventory.site.lan.domain}";
  jellystatPort = 3000;
  jellystatDatabase = "jfstat";
  jellystatUser = "jfstat";
  jellystatBackupDataDir = "/var/lib/jellystat/backup-data";
  jellystatOidcClientId = oidc.clients.jfstat.clientId;
  jellyfinUrl = "https://jf.${hostInventory.site.public.domain}";
  jellystatBackupScript = pkgs.writeShellApplication {
    name = "jellystat-built-in-backup";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      jq
    ];
    text = ''
      set -euo pipefail

      base_url="http://127.0.0.1:${toString jellystatPort}"
      backup_dir=${lib.escapeShellArg jellystatBackupDataDir}

      install -d -m 0750 -o root -g restic-cloud "$backup_dir"
      marker="$(mktemp "$backup_dir/.backup-marker.XXXXXX")"
      trap 'rm -f "$marker"' EXIT

      for attempt in $(seq 1 120); do
        config_json="$(curl --fail --silent "$base_url/auth/isConfigured" 2>/dev/null || true)"
        state="$(printf '%s' "$config_json" | jq --raw-output '.state // empty' 2>/dev/null || true)"

        if [ "$state" = 2 ]; then
          break
        fi

        if [ "$attempt" = 120 ]; then
          echo "Timed out waiting for Jellystat to become configured" >&2
          exit 1
        fi

        sleep 2
      done

      login_response="$(
        curl \
          --fail \
          --silent \
          --show-error \
          --header 'Content-Type: application/json' \
          --data-binary '{}' \
          "$base_url/auth/login"
      )"
      token="$(printf '%s' "$login_response" | jq --raw-output '.token // empty')"

      if [ -z "$token" ] || [ "$token" = "null" ]; then
        echo "Jellystat login did not return a backup token" >&2
        printf '%s\n' "$login_response" >&2
        exit 1
      fi

      curl \
        --fail \
        --silent \
        --show-error \
        --header "Authorization: Bearer $token" \
        "$base_url/backup/beginBackup"

      created_file="$(find "$backup_dir" -maxdepth 1 -type f -name 'backup_*.json' -newer "$marker" -print -quit)"
      if [ -z "$created_file" ]; then
        echo "Jellystat backup endpoint did not create a new backup file in $backup_dir" >&2
        exit 1
      fi
    '';
  };
in
{
  sops.secrets = {
    "jellyfin/apiKey" = {
      restartUnits = [
        "jellystat-bootstrap.service"
        "podman-jellystat.service"
      ];
    };
    "jellystat/postgres/password" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [
        "jellystat-postgresql-password.service"
        "podman-jellystat.service"
      ];
    };
    "jellystat/jwtSecret" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "podman-jellystat.service" ];
    };
  };

  sops.templates."jellystat.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      POSTGRES_PASSWORD=${config.sops.placeholder."jellystat/postgres/password"}
      JWT_SECRET=${config.sops.placeholder."jellystat/jwtSecret"}
    '';
    restartUnits = [ "podman-jellystat.service" ];
  };

  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    settings.listen_addresses = lib.mkForce "127.0.0.1";
    ensureDatabases = [ jellystatDatabase ];
    ensureUsers = [
      {
        name = jellystatUser;
        ensureDBOwnership = true;
      }
    ];
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.jellystat = {
      image = jellystatImage;
      imageFile = jellystatImageFile;
      pull = "never";
      environment = {
        POSTGRES_USER = jellystatUser;
        POSTGRES_IP = "127.0.0.1";
        POSTGRES_PORT = "5432";
        POSTGRES_DB = jellystatDatabase;
        POSTGRES_ROLE = jellystatUser;
        TZ = "America/New_York";
        JS_LISTEN_IP = "127.0.0.1";
        JS_BASE_URL = "/";
        JF_USE_WEBSOCKETS = "true";
        MINIMUM_SECONDS_TO_INCLUDE_PLAYBACK = "10";
        NEW_WATCH_EVENT_THRESHOLD_HOURS = "1";
      };
      environmentFiles = [ config.sops.templates."jellystat.env".path ];
      extraOptions = [
        "--cap-drop=all"
        "--network=host"
        "--security-opt=no-new-privileges"
      ];
      volumes = [ "${jellystatBackupDataDir}:/app/backend/backup-data:rw" ];
    };
  };

  systemd.tmpfiles.rules = [
    "d ${jellystatBackupDataDir} 0750 root restic-cloud - -"
  ];

  systemd.services = {
    jellystat-postgresql-password = {
      description = "Apply Jellystat PostgreSQL password";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      after = [
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      before = [ "podman-jellystat.service" ];
      path = [
        pkgs.postgresql
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        password="$(cat ${config.sops.secrets."jellystat/postgres/password".path})"
        runuser -u postgres -- psql --set=ON_ERROR_STOP=1 --set=password="$password" <<'SQL'
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jfstat') THEN
            CREATE ROLE jfstat LOGIN;
          END IF;
        END
        $$;
        ALTER ROLE jfstat WITH LOGIN PASSWORD :'password';
        SQL
      '';
    };

    jellystat-bootstrap = {
      description = "Bootstrap Jellystat configuration";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "podman-jellystat.service"
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      after = [
        "podman-jellystat.service"
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "12h";
      };
      script = ''
        base_url="http://127.0.0.1:${toString jellystatPort}"

        post_json() {
          local path="$1"
          local payload="$2"
          curl \
            --fail \
            --silent \
            --show-error \
            --header 'Content-Type: application/json' \
            --data-binary "$payload" \
            "$base_url$path"
        }

        post_json_auth() {
          local path="$1"
          local payload="$2"
          local token="$3"
          curl \
            --fail \
            --silent \
            --show-error \
            --header 'Content-Type: application/json' \
            --header "Authorization: Bearer $token" \
            --data-binary "$payload" \
            "$base_url$path"
        }

        get_json_auth() {
          local path="$1"
          local token="$2"
          curl \
            --fail \
            --silent \
            --show-error \
            --header "Authorization: Bearer $token" \
            "$base_url$path"
        }

        for attempt in $(seq 1 120); do
          config_json="$(curl --fail --silent "$base_url/auth/isConfigured" 2>/dev/null || true)"
          state="$(printf '%s' "$config_json" | jq --raw-output '.state // empty' 2>/dev/null || true)"

          if [ -n "$state" ]; then
            break
          fi

          if [ "$attempt" = 120 ]; then
            echo "Timed out waiting for Jellystat setup API" >&2
            exit 1
          fi

          sleep 2
        done

        jellyfin_api_key="$(tr -d '\n' < ${lib.escapeShellArg config.sops.secrets."jellyfin/apiKey".path})"
        config_payload="$(jq --null-input --compact-output \
          --arg JF_HOST ${lib.escapeShellArg jellyfinUrl} \
          --arg JF_API_KEY "$jellyfin_api_key" \
          '{ JF_HOST: $JF_HOST, JF_API_KEY: $JF_API_KEY }')"
        token=""

        if [ "$state" -lt 2 ]; then
          user_payload="$(jq --null-input --compact-output \
            --arg username oauth2-proxy \
            --arg password disabled \
            '{ username: $username, password: $password }')"
          user_response="$(post_json /auth/createuser "$user_payload")"
          token="$(printf '%s' "$user_response" | jq --raw-output '.token // empty')"

          post_json /auth/configSetup "$config_payload" >/dev/null
        fi

        if [ -z "$token" ]; then
          login_payload="$(jq --null-input --compact-output '{}')"
          login_response="$(post_json /auth/login "$login_payload" 2>/dev/null || true)"
          token="$(printf '%s' "$login_response" | jq --raw-output '.token // empty' 2>/dev/null || true)"
        fi

        if [ -n "$token" ]; then
          post_json_auth /api/setconfig "$config_payload" "$token" >/dev/null

          login_payload="$(jq --null-input --compact-output '{ REQUIRE_LOGIN: false }')"
          post_json_auth /api/setRequireLogin "$login_payload" "$token" >/dev/null

          library_metadata="$(get_json_auth /stats/getLibraryMetadata "$token")"
          library_count="$(printf '%s' "$library_metadata" | jq 'length')"

          if [ "$library_count" = 0 ]; then
            get_json_auth /sync/beginSync "$token" >/dev/null
          fi
        else
          echo "Jellystat is already configured and did not issue a bootstrap token; leaving app login unchanged." >&2
        fi
      '';
    };

    jellystat-built-in-backup = {
      description = "Create a built-in Jellystat backup artifact";
      restartIfChanged = false;
      stopIfChanged = false;
      before = [ "restic-backups-beast.service" ];
      wants = [ "podman-jellystat.service" ];
      after = [ "podman-jellystat.service" ];
      unitConfig.RequiresMountsFor = [ jellystatBackupDataDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = lib.getExe jellystatBackupScript;
        TimeoutStartSec = "12h";
      };
    };

    podman-jellystat = {
      wants = [
        "jellystat-postgresql-password.service"
        "sops-install-secrets.service"
      ];
      after = [
        "jellystat-postgresql-password.service"
        "sops-install-secrets.service"
      ];
      unitConfig.RequiresMountsFor = [ jellystatBackupDataDir ];
    };

    restic-backups-beast = {
      after = [ "jellystat-built-in-backup.service" ];
      wants = [ "jellystat-built-in-backup.service" ];
      requires = [ "jellystat-built-in-backup.service" ];
    };
  };

  services.restic.backups.beast.paths = [ jellystatBackupDataDir ];

  host.observability.backupMetrics.jobs.jellystat-built-in-backup = {
    service = "jellystat-built-in-backup";
    title = "Jellystat Built-In Backup";
    phase = "prep";
  };

  host.internalHttps.services.jfstat = {
    enable = true;
    upstream = "http://127.0.0.1:${toString jellystatPort}";
    locationExtraConfig = ''
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    '';
  };

  host.sso.oauth2ProxyGates.jfstat = {
    enable = true;
    clientId = jellystatOidcClientId;
    httpAddress = "http://127.0.0.1:4181";
    cookieName = "_jfstat_sso";
    allowedGroups = [ "media-admins" ];
    groupClaim = "media_groups";
    whitelistDomains = [ jellystatHostName ];
    internalHttpsServiceNames = [ "jfstat" ];
    clearAuthorizationHeader = false;
    extraLocationsByName.jfstat."= /auth/isConfigured" = {
      proxyPass = "http://127.0.0.1:${toString jellystatPort}";
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };
}
