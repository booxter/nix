{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  ociImages = builtins.fromJSON (builtins.readFile ../../lib/oci-images.json);
  jellystatImage = "${ociImages.jellystat.image}:${ociImages.jellystat.tag}";
  jellystatHostName = "jfstat.${hostInventory.site.lan.domain}";
  jellystatPort = 3000;
  jellystatDatabase = "jfstat";
  jellystatUser = "jfstat";
  jellystatBackupDataDir = "/var/lib/jellystat/backup-data";
  jellystatOidcClientId = oidc.clients.jfstat.clientId;
in
{
  sops.secrets = {
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
      pull = "missing";
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
    "d ${jellystatBackupDataDir} 0750 root root - -"
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
  };

  host.internalHttps.services.jfstat = {
    enable = true;
    upstream = "http://127.0.0.1:${toString jellystatPort}";
    mtls.enable = true;
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
    extraLocationsByName.jfstat."= /auth/isConfigured" = {
      proxyPass = "http://127.0.0.1:${toString jellystatPort}";
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };
}
