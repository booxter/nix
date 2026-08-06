{
  config,
  hostInventory,
  lib,
  pkgs,
  srvarrPkgs,
  utils,
  ...
}:
let
  accounts = import ./accounts.nix;
  ociImages = import ../../lib/oci-images { inherit pkgs; };
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };

  pinepodsService = hostInventory.servicesById.pinepods;
  pinepodsSso = hostInventory.sso.applications.pinepods;
  bootstrapOwnerName = pinepodsSso.bootstrapOwner;
  bootstrapAdmin = hostInventory.sso.users.${bootstrapOwnerName};
  oidcClientId = oidc.clients.pinepods.clientId;
  image = ociImages.pinepods.ref;
  imageFile = ociImages.pinepods.imageFile;

  user = "pinepods";
  database = "pinepods";
  port = 8040;
  valkeyPort = 6382;
  stateDir = "${config.host.srvarrPaths.stateDir}/pinepods";
  databaseDir = "${stateDir}/postgresql";
  backupDir = "${stateDir}/backups";
  downloadsDir = "${config.host.srvarrPaths.mediaDir}/podcasts/pinepods";

  serviceDependencies = [
    "network-online.target"
    "pinepods-postgresql-password.service"
    "pinepods-valkey.service"
    "sops-install-secrets.service"
  ];
  setDatabasePasswordCommand = utils.escapeSystemdExecArgs [
    (lib.getExe pkgs.postgresql-role-password)
    "--database"
    database
    "--role"
    user
    "--password-file"
    config.sops.secrets."pinepods/postgresql/password".path
  ];
  bootstrapAdminCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' srvarrPkgs.pinepods-tools "pinepods-bootstrap-admin")
    "--url"
    "http://127.0.0.1:${toString port}"
    "--username"
    bootstrapOwnerName
    "--full-name"
    bootstrapAdmin.displayName
    "--email-file"
    config.sops.secrets."pinepods/bootstrap/email".path
    "--password-file"
    config.sops.secrets."pinepods/bootstrap/password".path
  ];
  nativeBackupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' srvarrPkgs.pinepods-tools "pinepods-native-backup")
    "--url"
    "http://127.0.0.1:${toString port}"
    "--database"
    database
    "--keep"
    "7"
  ];
in
{
  sops.secrets = {
    "pinepods/postgresql/password" = {
      owner = "postgres";
      group = "postgres";
      mode = "0400";
      restartUnits = [
        "pinepods-postgresql-password.service"
        "podman-pinepods.service"
      ];
    };
    "pinepods/valkey/password" = {
      mode = "0400";
      restartUnits = [
        "pinepods-valkey.service"
        "podman-pinepods.service"
      ];
    };
    "pinepods/oidc/client_secret" = {
      mode = "0400";
      restartUnits = [ "podman-pinepods.service" ];
    };
    "pinepods/bootstrap/password" = {
      mode = "0400";
      restartUnits = [ "pinepods-bootstrap-admin.service" ];
    };
    "pinepods/bootstrap/email" = {
      mode = "0400";
      restartUnits = [ "pinepods-bootstrap-admin.service" ];
    };
  };

  sops.templates = {
    "pinepods.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        DB_PASSWORD=${config.sops.placeholder."pinepods/postgresql/password"}
        VALKEY_PASSWORD=${config.sops.placeholder."pinepods/valkey/password"}
        OIDC_CLIENT_SECRET=${config.sops.placeholder."pinepods/oidc/client_secret"}
      '';
      restartUnits = [ "podman-pinepods.service" ];
    };

    "pinepods-valkey.conf" = {
      owner = user;
      group = "media";
      mode = "0400";
      content = ''
        bind 127.0.0.1
        protected-mode yes
        port ${toString valkeyPort}
        daemonize no
        supervised no
        dir /run/pinepods-valkey
        save ""
        appendonly no
        requirepass ${config.sops.placeholder."pinepods/valkey/password"}
      '';
      restartUnits = [ "pinepods-valkey.service" ];
    };
  };

  users.users = {
    ${user} = {
      group = "media";
      home = "/var/empty";
      isSystemUser = true;
      uid = accounts.uids.pinepods;
    };
    postgres.extraGroups = [ "media" ];
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0750 root media - -"
    "d '${databaseDir}' 0700 postgres postgres - -"
    "d '${backupDir}' 0750 ${user} media - -"
  ];

  services.postgresql = {
    enable = true;
    dataDir = databaseDir;
    enableTCPIP = true;
    settings = {
      listen_addresses = lib.mkForce "127.0.0.1";
      password_encryption = "scram-sha-256";
    };
    authentication = lib.mkAfter ''
      host ${database} ${user} 127.0.0.1/32 scram-sha-256
    '';
    ensureDatabases = [ database ];
    ensureUsers = [
      {
        name = user;
        ensureDBOwnership = true;
      }
    ];
  };

  virtualisation = {
    podman.extraPackages = [ pkgs.slirp4netns ];
    oci-containers = {
      backend = "podman";
      containers.pinepods = {
        inherit image imageFile;
        pull = "never";
        environment = {
          DB_TYPE = "postgresql";
          DB_HOST = "10.0.2.2";
          DB_PORT = "5432";
          DB_USER = user;
          DB_NAME = database;
          VALKEY_HOST = "10.0.2.2";
          VALKEY_PORT = toString valkeyPort;
          HOSTNAME = pinepodsService.url;
          PINEPODS_PORT = "443";
          PROXY_PROTOCOL = "https";
          REVERSE_PROXY = "False";
          SEARCH_API_URL = "https://search.pinepods.online/api/search";
          PEOPLE_API_URL = "https://people.pinepods.online";
          DEBUG_MODE = "true";
          DEFAULT_LANGUAGE = "en";
          TZ = "America/New_York";
          PUID = toString accounts.uids.pinepods;
          PGID = toString hostInventory.site.gids.media;

          # Keep local login available for gPodder-compatible mobile/API clients,
          # while making SSO the normal browser account-provisioning path.
          OIDC_DISABLE_STANDARD_LOGIN = "false";
          OIDC_PROVIDER_NAME = "SSO";
          OIDC_CLIENT_ID = oidcClientId;
          OIDC_AUTHORIZATION_URL = oidc.authorizationUrl;
          OIDC_TOKEN_URL = oidc.tokenUrl;
          OIDC_USER_INFO_URL = oidc.userinfoUrl oidcClientId;
          OIDC_BUTTON_TEXT = "Login with SSO";
          OIDC_SCOPE = lib.concatStringsSep " " (oidc.scopeWith [ "pinepods_roles" ]);
          OIDC_BUTTON_COLOR = "#111827";
          OIDC_BUTTON_TEXT_COLOR = "#ffffff";
          OIDC_NAME_CLAIM = "name";
          OIDC_EMAIL_CLAIM = "email";
          OIDC_USERNAME_CLAIM = "preferred_username";
          OIDC_ROLES_CLAIM = "pinepods_roles";
          OIDC_USER_ROLE = "user";
          OIDC_ADMIN_ROLE = "admin";
        };
        environmentFiles = [ config.sops.templates."pinepods.env".path ];
        ports = [ "127.0.0.1:${toString port}:8040" ];
        networks = [ "slirp4netns:allow_host_loopback=true" ];
        volumes = [
          "${downloadsDir}:/opt/pinepods/downloads:rw"
          "${backupDir}:/opt/pinepods/backups:rw"
        ];
        extraOptions = [
          "--cap-drop=all"
          # The upstream entrypoint starts as root, chowns its writable paths,
          # creates nginx runtime paths owned by the image's nginx user, then
          # uses su-exec to switch to PUID:PGID. Retain only the capabilities
          # required for that startup and privilege-drop path.
          "--cap-add=CHOWN"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=SETGID"
          "--cap-add=SETUID"
          "--security-opt=no-new-privileges"
        ];
      };
    };
  };

  systemd.services = {
    postgresql = {
      after = [ "systemd-tmpfiles-setup.service" ];
    };

    pinepods-postgresql-password = {
      description = "Apply PinePods PostgreSQL password";
      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql-setup.service" ];
      wants = [ "sops-install-secrets.service" ];
      after = [
        "postgresql-setup.service"
        "sops-install-secrets.service"
      ];
      before = [ "podman-pinepods.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
        ExecStart = setDatabasePasswordCommand;
      };
    };

    pinepods-valkey = {
      description = "PinePods Valkey cache and task queue";
      wantedBy = [ "multi-user.target" ];
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      before = [ "podman-pinepods.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.valkey}/bin/valkey-server ${config.sops.templates."pinepods-valkey.conf".path}";
        User = user;
        Group = "media";
        RuntimeDirectory = "pinepods-valkey";
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        RemoveIPC = true;
      };
    };

    pinepods-bootstrap-admin = {
      description = "Create the initial PinePods administrator";
      wantedBy = [ "multi-user.target" ];
      requires = [ "podman-pinepods.service" ];
      wants = [ "sops-install-secrets.service" ];
      after = [
        "podman-pinepods.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5min";
        ExecStart = bootstrapAdminCommand;
      };
    };

    podman-pinepods = {
      requires = [
        "pinepods-postgresql-password.service"
        "pinepods-valkey.service"
      ];
      wants = serviceDependencies;
      after = serviceDependencies ++ [ "systemd-tmpfiles-setup.service" ];
      path = [ pkgs.slirp4netns ];
      environment.PINEPODS_LISTEN_PORT = toString port;
      unitConfig.RequiresMountsFor = [
        stateDir
        downloadsDir
      ];
    };

    pinepods-native-backup = {
      description = "Create a native PinePods database backup";
      restartIfChanged = false;
      stopIfChanged = false;
      requires = [ "podman-pinepods.service" ];
      after = [ "podman-pinepods.service" ];
      unitConfig.RequiresMountsFor = [ backupDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
        ExecStart = nativeBackupCommand;
        TimeoutStartSec = "2h15m";
      };
    };

  };

  host.backups.jobs.beast.preparations.pinepods-native-backup = {
    service = "pinepods-native-backup";
    title = "PinePods Native Backup";
  };

  host.internalHttps.services.pinepods = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
    publicAliases = [ pinepodsService.publicHost ];
    mtls.enable = true;
    recommendedProxySettings = false;
    locationExtraConfig = ''
      proxy_set_header Host ${pinepodsService.publicHost};
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host ${pinepodsService.publicHost};
      proxy_set_header X-Forwarded-Server $hostname;
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    '';
  };

  assertions = [
    {
      assertion = builtins.elem pinepodsSso.adminGroup bootstrapAdmin.groups;
      message = "The PinePods bootstrap owner must belong to its SSO admin group.";
    }
    {
      assertion = builtins.elem pinepodsSso.userGroup bootstrapAdmin.groups;
      message = "The PinePods bootstrap owner must belong to its SSO user group.";
    }
  ];
}
