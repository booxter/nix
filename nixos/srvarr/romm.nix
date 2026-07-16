{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  rommSso = hostInventory.sso.applications.romm;
  rommAccessGroups = [
    rommSso.adminGroup
    rommSso.editorGroup
    rommSso.viewerGroup
  ];
  rommGroupsFor = person: builtins.filter (group: builtins.elem group person.groups) rommAccessGroups;
  rommAdmins = lib.filterAttrs (
    _: person: builtins.elem rommSso.adminGroup person.groups
  ) hostInventory.sso.users;
  rommAuthorizedUsers = lib.filterAttrs (
    _: person: rommGroupsFor person != [ ]
  ) hostInventory.sso.users;
  mediaUsers = lib.filterAttrs (
    _: person: builtins.elem "media-users" person.groups
  ) hostInventory.sso.users;
  mediaDir = config.host.srvarrPaths.mediaDir;
  # RomM's upstream layout keeps all mutable application data under one root:
  # library, resources, assets, config, sync, and launchbox.
  rommBasePath = "${mediaDir}/romm";
  stateDir = "${config.host.srvarrPaths.stateDir}/romm";
  # Host-local MariaDB singleton. RomM is the only current consumer, but keep
  # the storage path neutral so future local databases can share it explicitly.
  mysqlDataDir = "${config.host.srvarrPaths.stateDir}/mysql";
  webDir = "${stateDir}/web";
  nginxDir = "${stateDir}/nginx";
  valkeyDir = "${stateDir}/valkey";
  user = "romm";
  apiPort = 5081;
  redisPort = 6380;
  rommDefaultCoreHeadReplacement = "  <script src=\"/assets/romm-default-core.js\"></script>\n</head>";
  rommDefaultCoreScript = pkgs.writeText "romm-default-core.js" ''
    (() => {
      const platform = "arcade";
      const defaultCore = "mame2003_plus";
      const previousDefaultCore = "mame2003";
      const key = `player:''${platform}:core`;
      const migrationKey = `player:''${platform}:core-default:''${defaultCore}`;

      try {
        const currentCore = window.localStorage.getItem(key);

        if (currentCore === null) {
          window.localStorage.setItem(key, defaultCore);
          window.localStorage.setItem(migrationKey, "true");
          return;
        }

        if (
          currentCore === previousDefaultCore &&
          window.localStorage.getItem(migrationKey) !== "true"
        ) {
          window.localStorage.setItem(key, defaultCore);
          window.localStorage.setItem(migrationKey, "true");
        }
      } catch (_error) {
        // Browser storage can be unavailable in restricted/private contexts.
      }
    })();
  '';
  rommReplaceFail = pkgs.writeShellScript "romm-replace-fail" ''
    set -euo pipefail

    if [ "$#" -ne 3 ]; then
      echo "usage: $0 <file> <pattern> <replacement>" >&2
      exit 2
    fi

    pattern=$2
    replacement=$3

    ${pkgs.perl}/bin/perl -0pi -e '
      BEGIN {
        $pattern = shift @ARGV;
        $replacement = shift @ARGV;
        $file = $ARGV[0] // "<input>";
        $matches = 0;
      }

      $matches += s/\Q$pattern\E/$replacement/g;

      END {
        if ($matches == 0) {
          print STDERR "replace-fail: pattern not found in $file\n";
          exit 1;
        }
      }
    ' "$pattern" "$replacement" "$1"
  '';
  ociImages = import ../../lib/oci-images.nix { inherit pkgs; };
  rommImage = ociImages.romm.ref;
  rommImageFile = ociImages.romm.imageFile;
  rommService = hostInventory.servicesById.romm;
  rommOidcClientId = oidc.clients.romm.clientId;

  commonEnvironment = {
    PATH = "/src/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    PYTHONDONTWRITEBYTECODE = "1";
    PYTHONUNBUFFERED = "1";
    PYTHONPATH = "/backend";
    ROMM_BASE_URL = rommService.url;
    DB_HOST = "localhost";
    DB_USER = "romm";
    DB_QUERY_JSON = builtins.toJSON {
      unix_socket = "/run/mysqld/mysqld.sock";
    };
    # Rootless Podman uses slirp4netns. With allow_host_loopback enabled,
    # 10.0.2.2 reaches host loopback services without opening Valkey publicly.
    REDIS_HOST = "10.0.2.2";
    REDIS_PORT = toString redisPort;
    # Prefer near-real-time rescans driven by filesystem changes. This flag is
    # still needed with a separate watcher service because watcher.py exits when
    # upstream's default false value is in effect.
    ENABLE_RESCAN_ON_FILESYSTEM_CHANGE = "true";
    LAUNCHBOX_API_ENABLED = "true";
    # LaunchBox keeps its metadata in Valkey. Enable RomM's scheduled updater so
    # the local metadata store is populated and refreshed without a manual task.
    ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA = "true";
    HASHEOUS_API_ENABLED = "true";
    DISABLE_USERPASS_LOGIN = "true";
    OIDC_ENABLED = "true";
    OIDC_AUTOLOGIN = "false";
    OIDC_PROVIDER = "SSO";
    OIDC_CLIENT_ID = rommOidcClientId;
    OIDC_REDIRECT_URI = "${rommService.url}/api/oauth/openid";
    OIDC_SERVER_APPLICATION_URL = oidc.openidBaseUrl rommOidcClientId;
    OIDC_SERVER_METADATA_URL = oidc.discoveryUrl rommOidcClientId;
    OIDC_CLAIM_ROLES = "romm_roles";
    OIDC_ROLE_ADMIN = rommSso.adminGroup;
    # RomM 5 maps both legacy editor and viewer claims to its non-admin `user`
    # role. Viewers inherit the native default permission group. An editor must
    # additionally be assigned RomM's native Editor permission group.
    OIDC_ROLE_EDITOR = rommSso.editorGroup;
    OIDC_ROLE_VIEWER = rommSso.viewerGroup;
    OIDC_USERNAME_ATTRIBUTE = "preferred_username";
  };

  containerVolumes = [
    "${rommBasePath}:/romm:rw"
    "/run/mysqld:/run/mysqld:ro"
  ];

  containerNetworks = [ "slirp4netns:allow_host_loopback=true" ];

  commonContainer = {
    image = rommImage;
    imageFile = rommImageFile;
    pull = "never";
    podman.user = user;
    environment = commonEnvironment;
    environmentFiles = [ config.sops.templates."romm.env".path ];
    volumes = containerVolumes;
    networks = containerNetworks;
    workdir = "/backend";
    entrypoint = "/bin/bash";
    extraOptions = [
      "--cap-drop=all"
      "--security-opt=no-new-privileges"
    ];
  };

  setupBefore = [
    "mysql.service"
    "romm-db-init.service"
    "romm-valkey.service"
    "sops-install-secrets.service"
    # Never run an Alembic migration without first replacing the staged
    # logical dump with one from the current database revision.
    "romm-backup.service"
  ];

  runtimeAfter = setupBefore ++ [ "romm-setup.service" ];
  rommUserRuntimeUnits = [
    "user-runtime-dir@${toString accounts.uids.romm}.service"
    "user@${toString accounts.uids.romm}.service"
  ];
  rommPodmanBaseUnits = rommUserRuntimeUnits ++ [ "network-online.target" ];
  rommPodmanRuntimeUnits = rommPodmanBaseUnits ++ runtimeAfter;

  tmpfilesSetupUnits = [
    "systemd-tmpfiles-setup.service"
    "systemd-tmpfiles-resetup.service"
  ];

  podmanRuntimeEnvironment = {
    HOME = stateDir;
    XDG_RUNTIME_DIR = "/run/user/${toString accounts.uids.romm}";
  };

  podmanRunArgs = [
    "--rm"
    "--name=romm-setup"
    "--log-driver=journald"
    "--env-file"
    config.sops.templates."romm.env".path
  ]
  ++ lib.flatten (
    lib.mapAttrsToList (name: value: [
      "-e"
      "${name}=${value}"
    ]) commonEnvironment
  )
  ++ [
    "-v"
    "${rommBasePath}:/romm:rw"
    "-v"
    "/run/mysqld:/run/mysqld:ro"
    "--network=slirp4netns:allow_host_loopback=true"
    "--cap-drop=all"
    "--security-opt=no-new-privileges"
    "--entrypoint"
    "/bin/bash"
    "--pull=never"
    rommImage
  ];

  podmanRunCommon = lib.concatMapStringsSep " " lib.escapeShellArg podmanRunArgs;
in
{
  sops.secrets = {
    "romm/authSecretKey" = { };
    "romm/dbPassword" = { };
    "romm/oidc/clientSecret" = {
      owner = user;
      group = "media";
      mode = "0400";
      restartUnits = [
        "romm-setup.service"
        "podman-romm-api.service"
        "podman-romm-scheduler.service"
        "podman-romm-worker.service"
        "podman-romm-watcher.service"
      ];
    };
  };

  sops.templates."romm.env" = {
    owner = user;
    group = "media";
    mode = "0400";
    content = ''
      ROMM_AUTH_SECRET_KEY=${config.sops.placeholder."romm/authSecretKey"}
      DB_PASSWD=${config.sops.placeholder."romm/dbPassword"}
      OIDC_CLIENT_SECRET=${config.sops.placeholder."romm/oidc/clientSecret"}
    '';
    restartUnits = [
      "romm-db-init.service"
      "romm-setup.service"
      "podman-romm-api.service"
      "podman-romm-scheduler.service"
      "podman-romm-worker.service"
      "podman-romm-watcher.service"
    ];
  };

  users.users = {
    ${user} = {
      isSystemUser = true;
      group = "media";
      home = stateDir;
      uid = accounts.uids.romm;
      linger = true;
      autoSubUidGidRange = true;
    };
    ${config.services.nginx.user}.extraGroups = [ "media" ];
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0750 ${user} media - -"
    "d '${webDir}' 0750 ${user} media - -"
    "d '${nginxDir}' 0750 ${user} media - -"
    "d '${valkeyDir}' 0750 ${user} media - -"
    "d '${rommBasePath}' 2775 ${user} media - -"
    "d '${rommBasePath}/assets' 2775 ${user} media - -"
    "d '${rommBasePath}/config' 2775 ${user} media - -"
    "d '${rommBasePath}/resources' 2775 ${user} media - -"
    "d '${rommBasePath}/sync' 2775 ${user} media - -"
    "d '${rommBasePath}/library' 2775 ${user} media - -"
    "d '${rommBasePath}/library/roms' 2775 ${user} media - -"
    "d '${rommBasePath}/library/bios' 2775 ${user} media - -"
  ];

  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    dataDir = mysqlDataDir;
    settings.mysqld.skip-networking = true;
  };

  systemd.services.mysql.after = tmpfilesSetupUnits;

  systemd.services.romm-db-init = {
    description = "Initialize RomM MariaDB database";
    wants = [
      "mysql.service"
      "sops-install-secrets.service"
    ];
    after = [
      "mysql.service"
      "sops-install-secrets.service"
    ]
    ++ tmpfilesSetupUnits;
    unitConfig.RequiresMountsFor = config.host.srvarrPaths.stateDir;
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.sops.templates."romm.env".path;
    };
    script = ''
      set -euo pipefail

      ${pkgs.mariadb}/bin/mariadb --protocol=socket -u root <<SQL
      CREATE DATABASE IF NOT EXISTS romm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER IF NOT EXISTS 'romm'@'localhost' IDENTIFIED BY '$DB_PASSWD';
      ALTER USER 'romm'@'localhost' IDENTIFIED BY '$DB_PASSWD';
      GRANT ALL PRIVILEGES ON romm.* TO 'romm'@'localhost';
      FLUSH PRIVILEGES;
      SQL
    '';
  };

  systemd.services.romm-valkey = {
    description = "RomM Valkey cache and queue";
    wantedBy = [ "multi-user.target" ];
    after = tmpfilesSetupUnits;
    unitConfig.RequiresMountsFor = config.host.srvarrPaths.stateDir;
    serviceConfig = {
      ExecStart = "${pkgs.valkey}/bin/valkey-server --bind 127.0.0.1 --port ${toString redisPort} --dir ${valkeyDir} --appendonly yes --save 60 1";
      User = user;
      Group = "media";
      WorkingDirectory = valkeyDir;
      UMask = "0007";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ valkeyDir ];
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

  systemd.services.romm-web-assets = {
    description = "Extract RomM web assets from upstream OCI image";
    wantedBy = [ "multi-user.target" ];
    wants = rommPodmanBaseUnits;
    after = rommPodmanBaseUnits ++ tmpfilesSetupUnits;
    unitConfig.RequiresMountsFor = stateDir;
    path = [
      pkgs.coreutils
      config.virtualisation.podman.package
    ];
    environment = podmanRuntimeEnvironment;
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "media";
      WorkingDirectory = stateDir;
      UMask = "0027";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      podman load -i ${lib.escapeShellArg "${rommImageFile}"}
      cid="$(podman create ${lib.escapeShellArg rommImage})"
      cleanup() {
        podman rm -f "$cid" >/dev/null 2>&1 || true
      }
      trap cleanup EXIT

      rm -rf ${lib.escapeShellArg "${webDir}.new"} ${lib.escapeShellArg "${nginxDir}.new"}
      mkdir -p ${lib.escapeShellArg "${webDir}.new"} ${lib.escapeShellArg "${nginxDir}.new"}
      podman cp "$cid:/var/www/html/." ${lib.escapeShellArg "${webDir}.new/"}
      podman cp "$cid:/etc/nginx/js/." ${lib.escapeShellArg "${nginxDir}.new/"}

      install -m 0644 ${rommDefaultCoreScript} ${lib.escapeShellArg "${webDir}.new/assets/romm-default-core.js"}
      ${rommReplaceFail} \
        ${lib.escapeShellArg "${webDir}.new/index.html"} \
        ${lib.escapeShellArg "</head>"} \
        ${lib.escapeShellArg rommDefaultCoreHeadReplacement}

      rm -f ${lib.escapeShellArg "${webDir}.new/assets/romm/resources"}
      mkdir -p ${lib.escapeShellArg "${webDir}.new/assets/romm"}

      rm -rf ${lib.escapeShellArg "${webDir}.old"} ${lib.escapeShellArg "${nginxDir}.old"}
      if [ -e ${lib.escapeShellArg webDir} ]; then
        mv ${lib.escapeShellArg webDir} ${lib.escapeShellArg "${webDir}.old"}
      fi
      if [ -e ${lib.escapeShellArg nginxDir} ]; then
        mv ${lib.escapeShellArg nginxDir} ${lib.escapeShellArg "${nginxDir}.old"}
      fi
      mv ${lib.escapeShellArg "${webDir}.new"} ${lib.escapeShellArg webDir}
      mv ${lib.escapeShellArg "${nginxDir}.new"} ${lib.escapeShellArg nginxDir}
      rm -rf ${lib.escapeShellArg "${webDir}.old"} ${lib.escapeShellArg "${nginxDir}.old"}
    '';
  };

  systemd.services.romm-setup = {
    description = "Run RomM database migrations and startup tasks";
    wantedBy = [ "multi-user.target" ];
    wants = rommPodmanBaseUnits ++ setupBefore;
    requires = [ "romm-backup.service" ];
    after = rommPodmanBaseUnits ++ setupBefore ++ tmpfilesSetupUnits;
    unitConfig.RequiresMountsFor = [
      mediaDir
      stateDir
    ];
    path = [
      config.virtualisation.podman.package
      pkgs.slirp4netns
    ];
    environment = podmanRuntimeEnvironment;
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = "media";
      WorkingDirectory = stateDir;
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "5s";
    };
    script = ''
      set -euo pipefail

      podman load -i ${lib.escapeShellArg "${rommImageFile}"}
      podman run ${podmanRunCommon} \
        -c 'cd /backend && alembic upgrade head && python3 startup.py'
    '';
  };

  virtualisation = {
    podman.extraPackages = [ pkgs.slirp4netns ];
    oci-containers = {
      backend = "podman";
      containers = {
        romm-api = commonContainer // {
          ports = [ "127.0.0.1:${toString apiPort}:${toString apiPort}" ];
          cmd = [
            "-c"
            "exec gunicorn --bind 0.0.0.0:${toString apiPort} --forwarded-allow-ips='*' --worker-class uvicorn_worker.UvicornWorker --workers 1 --timeout 300 --keep-alive 2 --max-requests 1000 --max-requests-jitter 100 --worker-connections 1000 --error-logfile - main:app"
          ];
        };
        romm-worker = commonContainer // {
          cmd = [
            "-c"
            "exec rq worker --path /backend --url redis://10.0.2.2:${toString redisPort}/0 --results-ttl 86400 --logging_level INFO high default low"
          ];
        };
        romm-scheduler = commonContainer // {
          cmd = [
            "-c"
            "exec env RQ_REDIS_HOST=10.0.2.2 RQ_REDIS_PORT=${toString redisPort} RQ_REDIS_DB=0 RQ_REDIS_SSL=0 rqscheduler --path /backend --pid /tmp/rq_scheduler.pid"
          ];
        };
        romm-watcher = commonContainer // {
          cmd = [
            "-c"
            "exec watchfiles --target-type command 'python3 watcher.py' /romm/library"
          ];
        };
      };
    };
  };

  systemd.services = {
    podman-romm-api = {
      path = [ pkgs.slirp4netns ];
      requires = runtimeAfter;
      wants = lib.mkForce rommPodmanRuntimeUnits;
      after = lib.mkForce rommPodmanRuntimeUnits;
      environment = podmanRuntimeEnvironment;
    };
    podman-romm-worker = {
      path = [ pkgs.slirp4netns ];
      requires = runtimeAfter;
      wants = lib.mkForce rommPodmanRuntimeUnits;
      after = lib.mkForce rommPodmanRuntimeUnits;
      environment = podmanRuntimeEnvironment;
    };
    podman-romm-scheduler = {
      path = [ pkgs.slirp4netns ];
      requires = runtimeAfter;
      wants = lib.mkForce rommPodmanRuntimeUnits;
      after = lib.mkForce rommPodmanRuntimeUnits;
      environment = podmanRuntimeEnvironment;
    };
    podman-romm-watcher = {
      path = [ pkgs.slirp4netns ];
      requires = runtimeAfter;
      wants = lib.mkForce rommPodmanRuntimeUnits;
      after = lib.mkForce rommPodmanRuntimeUnits;
      environment = podmanRuntimeEnvironment;
    };
    nginx = {
      wants = [ "romm-web-assets.service" ];
      after = [ "romm-web-assets.service" ];
    };
  };

  services.nginx = {
    additionalModules = with pkgs.nginxModules; [
      njs
      zip
    ];
    commonHttpConfig = ''
      js_import ${nginxDir}/decode.js;

      map $request_uri $romm_coep_header {
          default "";
          ~^/rom/.*/ejs$ "require-corp";
          ~^/console/rom/[0-9]+/play "require-corp";
      }

      map $request_uri $romm_coop_header {
          default "";
          ~^/rom/.*/ejs$ "same-origin";
          ~^/console/rom/[0-9]+/play "same-origin";
      }
    '';
    virtualHosts."internal-https-romm" = {
      root = webDir;
      locations = {
        "/" = {
          tryFiles = "$uri $uri/ /index.html";
          extraConfig = ''
            proxy_redirect off;
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods *;
            add_header Access-Control-Allow-Headers *;
            add_header Cross-Origin-Embedder-Policy $romm_coep_header;
            add_header Cross-Origin-Opener-Policy $romm_coop_header;
          '';
        };
        "/assets/romm/resources/" = {
          extraConfig = ''
            # Covers and screenshots describe the private library. Reuse RomM's
            # own session/API-token validation before serving them from disk.
            auth_request /_romm_auth;
            alias ${rommBasePath}/resources/;
            add_header Cache-Control "private";
          '';
        };
        "/assets" = {
          tryFiles = "$uri $uri/ =404";
        };
        "= /_romm_auth" = {
          proxyPass = "http://127.0.0.1:${toString apiPort}/api/users/me";
          extraConfig = ''
            internal;
            proxy_set_header Content-Length "";
            proxy_pass_request_body off;
          '';
        };
        "= /openapi.json" = {
          # The browser client does not consume the API schema.
          return = "404";
        };
        "/api" = {
          extraConfig = ''
            proxy_request_buffering off;
            proxy_buffering off;
            proxy_read_timeout 300s;
          '';
        };
        "~ ^/(ws|netplay)" = {
          proxyPass = "http://127.0.0.1:${toString apiPort}";
          proxyWebsockets = true;
        };
        "/library/" = {
          extraConfig = ''
            internal;
            alias ${rommBasePath}/library/;
          '';
        };
        "/decode" = {
          extraConfig = ''
            internal;
            js_content decode.decodeBase64;
          '';
        };
      };
    };
  };

  host.internalHttps.services.romm = {
    enable = true;
    upstream = "http://127.0.0.1:${toString apiPort}";
    path = "/api";
    publicAliases = [ rommService.publicHost ];
    mtls.enable = true;
  };

  assertions = [
    {
      assertion = builtins.attrNames rommAdmins == [ rommSso.bootstrapOwner ];
      message = "The RomM bootstrap owner must be its only SSO administrator.";
    }
    {
      assertion = lib.all (person: builtins.length (rommGroupsFor person) == 1) (
        builtins.attrValues rommAuthorizedUsers
      );
      message = "Each RomM SSO user must belong to exactly one RomM access group.";
    }
    {
      assertion = lib.all (person: builtins.length (rommGroupsFor person) == 1) (
        builtins.attrValues mediaUsers
      );
      message = "Each media user must have exactly one RomM SSO access group.";
    }
  ];
}
