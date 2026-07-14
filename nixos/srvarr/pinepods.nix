{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  ociImages = import ../../lib/oci-images.nix { inherit pkgs; };
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
  nativeBackupScript = pkgs.writeShellApplication {
    name = "pinepods-native-backup";
    runtimeInputs = [
      config.services.postgresql.package
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      base_url=http://127.0.0.1:${toString port}
      # The bootstrap password is only used to create the initial account and
      # can change afterward. Read an existing admin key from the local
      # database instead of coupling scheduled backups to that old password.
      api_key="$(
        runuser -u postgres -- \
          psql \
            --dbname=${lib.escapeShellArg database} \
            --no-align \
            --quiet \
            --tuples-only \
            --command \
              "SELECT a.apikey
                 FROM \"APIKeys\" a
                 JOIN \"Users\" u ON u.userid = a.userid
                WHERE u.isadmin = true
                  AND u.username <> 'background_tasks'
                ORDER BY u.userid, a.apikeyid
                LIMIT 1;"
      )"
      if [ -z "$api_key" ]; then
        echo "PinePods has no API key for a non-background administrator" >&2
        exit 1
      fi

      backup_response="$(
        curl \
          --fail-with-body \
          --silent \
          --show-error \
          --request POST \
          --header "Api-Key: $api_key" \
          --header 'Content-Type: application/json' \
          --data '{}' \
          "$base_url/api/data/manual_backup_to_directory"
      )"
      task_id="$(printf '%s' "$backup_response" | jq --exit-status --raw-output '.task_id')"

      for attempt in $(seq 1 3600); do
        task_response="$(
          curl \
            --fail-with-body \
            --silent \
            --show-error \
            "$base_url/api/tasks/$task_id"
        )"
        status="$(printf '%s' "$task_response" | jq --exit-status --raw-output '.status')"
        case "$status" in
          SUCCESS)
            break
            ;;
          FAILED)
            printf 'PinePods native backup failed: %s\n' "$task_response" >&2
            exit 1
            ;;
          PENDING | DOWNLOADING)
            ;;
          *)
            printf 'PinePods returned an unknown backup task state: %s\n' "$task_response" >&2
            exit 1
            ;;
        esac

        if [ "$attempt" = 3600 ]; then
          echo "PinePods native backup timed out" >&2
          exit 1
        fi
        sleep 2
      done

      files_response="$(
        curl \
          --fail-with-body \
          --silent \
          --show-error \
          --request POST \
          --header "Api-Key: $api_key" \
          --header 'Content-Type: application/json' \
          --data '{}' \
          "$base_url/api/data/list_backup_files"
      )"
      mapfile -t old_backups < <(
        printf '%s' "$files_response" | jq --exit-status --raw-output '.backup_files[7:][]?.filename'
      )
      for backup_filename in "''${old_backups[@]}"; do
        jq --null-input --arg backup_filename "$backup_filename" \
          '{backup_filename: $backup_filename}' \
          | curl \
            --fail-with-body \
            --silent \
            --show-error \
            --request POST \
            --header "Api-Key: $api_key" \
            --header 'Content-Type: application/json' \
            --data-binary @- \
            "$base_url/api/data/delete_backup_file" \
            >/dev/null
      done
    '';
  };
in
{
  sops.secrets = {
    "pinepods/postgresql/password" = {
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
      path = [
        config.services.postgresql.package
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        password="$(cat ${config.sops.secrets."pinepods/postgresql/password".path})"
        runuser -u postgres -- psql --set=ON_ERROR_STOP=1 --set=password="$password" <<'SQL'
        ALTER ROLE pinepods WITH LOGIN PASSWORD :'password';
        SQL
      '';
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
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5min";
      };
      script = ''
        base_url="http://127.0.0.1:${toString port}"

        for attempt in $(seq 1 120); do
          status_json="$(
            curl --fail --silent "$base_url/api/data/self_service_status" 2>/dev/null \
              || true
          )"
          first_admin_created="$(
            printf '%s' "$status_json" \
              | jq --raw-output \
                'select((.first_admin_created | type) == "boolean") | .first_admin_created' \
                2>/dev/null \
              || true
          )"

          if [ "$first_admin_created" = "true" ]; then
            echo "PinePods already has an administrator"
            exit 0
          fi

          if [ "$first_admin_created" = "false" ]; then
            break
          fi

          if [ "$attempt" = 120 ]; then
            echo "Timed out waiting for the PinePods setup API" >&2
            exit 1
          fi

          sleep 2
        done

        response="$(
          jq \
            --null-input \
            --arg username ${lib.escapeShellArg bootstrapOwnerName} \
            --arg fullname ${lib.escapeShellArg bootstrapAdmin.displayName} \
            --arg email ${lib.escapeShellArg (builtins.head bootstrapAdmin.mailAddresses)} \
            --rawfile password ${config.sops.secrets."pinepods/bootstrap/password".path} \
            '{
              username: $username,
              fullname: $fullname,
              email: $email,
              password: ($password | sub("[\\r\\n]+$"; ""))
            }' \
            | curl \
              --fail \
              --silent \
              --show-error \
              --header 'Content-Type: application/json' \
              --data-binary @- \
              "$base_url/api/data/create_first"
        )"

        user_id="$(printf '%s' "$response" | jq --raw-output '.user_id // empty')"
        if [ -z "$user_id" ]; then
          echo "PinePods did not return the created administrator ID" >&2
          printf '%s\n' "$response" >&2
          exit 1
        fi

        echo "Created the initial PinePods administrator (user ID $user_id)"
      '';
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
      before = [ "restic-backups-beast.service" ];
      requires = [ "podman-pinepods.service" ];
      after = [ "podman-pinepods.service" ];
      unitConfig.RequiresMountsFor = [ backupDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = lib.getExe nativeBackupScript;
        TimeoutStartSec = "2h15m";
      };
    };

    restic-backups-beast = {
      after = [ "pinepods-native-backup.service" ];
      wants = [ "pinepods-native-backup.service" ];
      requires = [ "pinepods-native-backup.service" ];
    };
  };

  host.observability.backupMetrics.jobs.pinepods-native-backup = {
    service = "pinepods-native-backup";
    title = "PinePods Native Backup";
    phase = "prep";
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
