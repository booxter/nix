{
  beastPkgs,
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
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
  setDatabasePasswordCommand = utils.escapeSystemdExecArgs [
    (lib.getExe pkgs.postgresql-role-password)
    "--database"
    jellystatDatabase
    "--role"
    jellystatUser
    "--password-file"
    config.sops.secrets."jellystat/postgres/password".path
  ];
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.jellystat-tools "jellystat-bootstrap")
    "--url"
    "http://127.0.0.1:${toString jellystatPort}"
    "--jellyfin-url"
    jellyfinUrl
    "--jellyfin-api-key-file"
    config.sops.secrets."jellyfin/apiKey".path
  ];
  backupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.jellystat-tools "jellystat-built-in-backup")
    "--url"
    "http://127.0.0.1:${toString jellystatPort}"
    "--backup-dir"
    jellystatBackupDataDir
  ];
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
      owner = "postgres";
      group = "postgres";
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
      requires = [ "postgresql-setup.service" ];
      wants = [ "sops-install-secrets.service" ];
      after = [
        "postgresql-setup.service"
        "sops-install-secrets.service"
      ];
      before = [ "podman-jellystat.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        ExecStart = setDatabasePasswordCommand;
      };
    };

    jellystat-bootstrap = {
      description = "Bootstrap Jellystat configuration";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "jellyfin.service"
        "nginx.service"
        "podman-jellystat.service"
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      after = [
        "jellyfin.service"
        "nginx.service"
        "podman-jellystat.service"
        "postgresql.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "12h";
        ExecStart = bootstrapCommand;
      };
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
        ExecStart = backupCommand;
        TimeoutStartSec = "12h";
      };
    };

    podman-jellystat = {
      # Podman snapshots the host resolver configuration when it creates the
      # container, so wait for DHCP to populate resolv.conf first.
      wants = [
        "jellystat-postgresql-password.service"
        "network-online.target"
        "sops-install-secrets.service"
      ];
      after = [
        "jellystat-postgresql-password.service"
        "network-online.target"
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
