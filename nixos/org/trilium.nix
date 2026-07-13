{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  service = hostInventory.servicesById.notes;
  serviceName = "trilium";
  stateDir = "/var/lib/${serviceName}";
  oidcClientId = "trilium";
  port = 18086;
  bootstrapPort = 18087;
  serviceEnvironment = {
    TRILIUM_DATA_DIR = stateDir;
    TRILIUM_GENERAL_INSTANCENAME = "Trilium Notes";
    TRILIUM_NETWORK_HOST = "127.0.0.1";
    TRILIUM_NETWORK_PORT = toString port;
    TRILIUM_NETWORK_TRUSTEDREVERSEPROXY = "loopback";
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHBASEURL = service.url;
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHCLIENTID = oidcClientId;
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHISSUERBASEURL = oidc.openidBaseUrl oidcClientId;
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHISSUERNAME = "SSO";
  };
  bootstrapScript = pkgs.writeShellApplication {
    name = "trilium-bootstrap";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.sqlite
    ];
    text = ''
      database="''${TRILIUM_DATA_DIR}/document.db"
      base_url=${lib.escapeShellArg "http://127.0.0.1:${toString bootstrapPort}"}
      : "''${TRILIUM_LOCAL_PASSWORD_FILE:?}"

      database_value() {
        sqlite3 "$database" "$1" 2>/dev/null || true
      }

      is_initialized() {
        test -f "$database" &&
          test "$(database_value "SELECT value FROM options WHERE name = 'initialized';")" = "true"
      }

      is_password_set() {
        test -n "$(database_value "SELECT value FROM options WHERE name = 'passwordVerificationHash';")"
      }

      server_pid=""
      cleanup() {
        if test -n "$server_pid" && kill -0 "$server_pid" 2>/dev/null; then
          kill "$server_pid"
          wait "$server_pid" || true
        fi
        server_pid=""
      }
      trap cleanup EXIT

      needs_initialization=true
      is_initialized && needs_initialization=false
      needs_password=true
      is_password_set && needs_password=false

      if "$needs_initialization" || "$needs_password"; then
        ${lib.getExe pkgs.trilium-next-server} &
        server_pid=$!

        status=""
        for _ in $(seq 1 120); do
          if status="$(curl --fail --silent --show-error "$base_url/api/setup/status")"; then
            break
          fi
          if ! kill -0 "$server_pid" 2>/dev/null; then
            echo "Trilium exited before bootstrap completed" >&2
            exit 1
          fi
          sleep 1
        done
        if test -z "$status"; then
          echo "Timed out waiting for Trilium's setup API" >&2
          exit 1
        fi

        if test "$(jq --raw-output .isInitialized <<<"$status")" != "true"; then
          curl --fail --silent --show-error \
            --request POST \
            "$base_url/api/setup/new-document" \
            >/dev/null
        fi

        if ! is_password_set; then
          http_code="$(
            curl --silent --show-error \
              --output /dev/null \
              --write-out '%{http_code}' \
              --request POST \
              --data-urlencode "password1@''${TRILIUM_LOCAL_PASSWORD_FILE}" \
              --data-urlencode "password2@''${TRILIUM_LOCAL_PASSWORD_FILE}" \
              "$base_url/set-password"
          )"
          if test "$http_code" != "302"; then
            echo "Setting the Trilium break-glass password returned HTTP $http_code" >&2
            exit 1
          fi
        fi

        cleanup
      fi

      if ! is_initialized || ! is_password_set; then
        echo "Trilium database initialization did not complete" >&2
        exit 1
      fi

      sqlite3 "$database" "
        BEGIN IMMEDIATE;
        UPDATE options SET value = 'true' WHERE name = 'mfaEnabled';
        UPDATE options SET value = 'oauth' WHERE name = 'mfaMethod';
        COMMIT;
      "

      if test "$(database_value "SELECT value FROM options WHERE name = 'mfaMethod';")" != "oauth"; then
        echo "Trilium OIDC bootstrap did not complete" >&2
        exit 1
      fi
    '';
  };
in
{
  users.groups.${serviceName} = { };

  users.users.${serviceName} = {
    description = "Trilium Notes";
    isSystemUser = true;
    group = serviceName;
    home = stateDir;
  };

  sops.secrets = {
    trilium-local-password = {
      key = "trilium/local_password";
      owner = serviceName;
      group = serviceName;
      mode = "0400";
      restartUnits = [ "trilium-bootstrap.service" ];
    };
    trilium-oidc-client-secret = {
      key = "trilium/oidc/client_secret";
      restartUnits = [
        "trilium-bootstrap.service"
        "${serviceName}.service"
      ];
    };
  };

  sops.templates."trilium-oidc.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHCLIENTSECRET=${config.sops.placeholder.trilium-oidc-client-secret}
    '';
    restartUnits = [
      "trilium-bootstrap.service"
      "${serviceName}.service"
    ];
  };

  systemd.services = {
    trilium-bootstrap = {
      description = "Bootstrap Trilium Notes with OIDC";
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      before = [ "${serviceName}.service" ];
      environment = serviceEnvironment // {
        TRILIUM_LOCAL_PASSWORD_FILE = config.sops.secrets.trilium-local-password.path;
        TRILIUM_NETWORK_PORT = toString bootstrapPort;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = serviceName;
        Group = serviceName;
        EnvironmentFile = config.sops.templates."trilium-oidc.env".path;
        StateDirectory = serviceName;
        StateDirectoryMode = "0750";
        WorkingDirectory = stateDir;
        ExecStart = lib.getExe bootstrapScript;
        TimeoutStartSec = "5min";
        UMask = "0027";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    ${serviceName} = {
      description = "Trilium Notes";
      wantedBy = [ "multi-user.target" ];
      requires = [ "trilium-bootstrap.service" ];
      after = [ "trilium-bootstrap.service" ];
      environment = serviceEnvironment;
      serviceConfig = {
        User = serviceName;
        Group = serviceName;
        EnvironmentFile = config.sops.templates."trilium-oidc.env".path;
        StateDirectory = serviceName;
        StateDirectoryMode = "0750";
        WorkingDirectory = stateDir;
        ExecStart = lib.getExe pkgs.trilium-next-server;
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "20s";
        UMask = "0027";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };
  };

  host.internalHttps.services.notes = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
    publicAliases = [ service.publicHost ];
    mtls.enable = true;
    probe.enable = true;
    locationExtraConfig = ''
      client_max_body_size 0;
      proxy_buffer_size 128k;
      proxy_buffers 4 256k;
      proxy_busy_buffers_size 256k;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    '';
  };
}
