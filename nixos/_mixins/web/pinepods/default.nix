{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.pinepods;
  hostCfg = config.host.pinepods;
  hostname = config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  pinepodsAccount = hostInventory.serviceAccounts.pinepods;
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaGroup = mediaExport.sharedGroup;
  isMediaServer = mediaExport.server == hostname;
  ociImages = import ../../../../oci { inherit pkgs; };

  pinepodsService = hostInventory.servicesById.pinepods;
  instance = pinepodsService.instances.${hostname} or { };
  pinepodsSso = hostInventory.sso.applications.pinepods;
  administratorName = hostInventory.sso.administrator;
  administrator = hostInventory.sso.users.${administratorName};
  oidcClient = config.host.sso.oidc.clients.pinepods;
  oidcScopes = config.host.sso.oidc.baseScopes;
  image = ociImages.pinepods.ref;
  imageFile = ociImages.pinepods.imageFile;

  user = "pinepods";
  database = "pinepods";
  port = cfg.port;
  valkeyPort = 6382;
  stateDir = cfg.dataDir;
  databaseDir = "${stateDir}/postgresql";
  backupDir = "${stateDir}/backups";
  downloadsDir = cfg.downloadsDir;

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
    (lib.getExe' cfg.tools.package "pinepods-bootstrap-admin")
    "--url"
    cfg.localUrl
    "--username"
    administratorName
    "--full-name"
    administrator.displayName
    "--email-file"
    config.sops.secrets."pinepods/bootstrap/email".path
    "--password-file"
    config.sops.secrets."pinepods/bootstrap/password".path
  ];
  nativeBackupCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.tools.package "pinepods-native-backup")
    "--url"
    cfg.localUrl
    "--database"
    database
    "--keep"
    "7"
  ];
in
{
  options = {
    host.pinepods.enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname pinepodsService;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns PinePods to this host.";
    };

    services.pinepods = {
      enable = lib.mkEnableOption "PinePods";

      dataDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/pinepods";
        description = "Directory containing PinePods state.";
      };

      downloadsDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/pinepods/downloads";
        description = "Directory containing downloaded podcast media.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 8040;
        description = "Loopback port on which PinePods listens.";
      };

      localUrl = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        description = "Loopback URL for PinePods.";
      };

      tools.package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./packages/pinepods-tools { };
        description = "Package providing PinePods bootstrap and backup helpers.";
      };
    };
  };

  config = lib.mkMerge [
    {
      services.pinepods.localUrl = "http://127.0.0.1:${toString cfg.port}";
    }

    (lib.mkIf hostCfg.enable {
      services.pinepods = {
        enable = true;
        dataDir = instance.dataDir;
        downloadsDir = instance.downloadsDir;
      };

      host.nfs.mounts = lib.mkIf (!isMediaServer) {
        media = instance.mediaDir;
      };

      host.sso.oidc.registrations.pinepods = {
        displayName = "PinePods";
        originUrls = [ "${pinepodsService.url}/api/auth/callback" ];
        originLanding = "${pinepodsService.url}/";
        # PinePods 0.9.0 explicitly requires a confidential client without PKCE.
        allowInsecureClientDisablePkce = true;
        scopeMaps = {
          ${pinepodsSso.adminGroup} = oidcScopes ++ [ "pinepods_roles" ];
          ${pinepodsSso.userGroup} = oidcScopes ++ [ "pinepods_roles" ];
        };
        claimMaps.pinepods_roles.valuesByGroup = {
          ${pinepodsSso.adminGroup} = [ "admin" ];
          ${pinepodsSso.userGroup} = [ "user" ];
        };
        secret = {
          sopsKey = "pinepods/oidc/client_secret";
          name = "pinepods/oidc/client_secret";
          restartUnits = [ "podman-pinepods.service" ];
        };
      };

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
            OIDC_CLIENT_SECRET=${oidcClient.secret.placeholder}
          '';
          restartUnits = [ "podman-pinepods.service" ];
        };

        "pinepods-valkey.conf" = {
          owner = user;
          group = mediaGroup.name;
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
          group = mediaGroup.name;
          home = "/var/empty";
          isSystemUser = true;
          uid = pinepodsAccount.uid;
        };
        postgres.extraGroups = [ mediaGroup.name ];
      };

      systemd.tmpfiles.rules = [
        "d '${stateDir}' 0750 root ${mediaGroup.name} - -"
        "d '${databaseDir}' 0700 postgres postgres - -"
        "d '${backupDir}' 0750 ${user} ${mediaGroup.name} - -"
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
              DEFAULT_LANGUAGE = hostInventory.regional.language.code;
              TZ = config.time.timeZone;
              PUID = toString pinepodsAccount.uid;
              PGID = toString mediaGroup.gid;

              # Keep local login available for gPodder-compatible mobile/API clients,
              # while making SSO the normal browser account-provisioning path.
              OIDC_DISABLE_STANDARD_LOGIN = "false";
              OIDC_PROVIDER_NAME = "SSO";
              OIDC_CLIENT_ID = oidcClient.clientId;
              OIDC_AUTHORIZATION_URL = oidcClient.authorizationUrl;
              OIDC_TOKEN_URL = oidcClient.tokenUrl;
              OIDC_USER_INFO_URL = oidcClient.userinfoUrl;
              OIDC_BUTTON_TEXT = "Login with SSO";
              OIDC_SCOPE = lib.concatStringsSep " " (oidcScopes ++ [ "pinepods_roles" ]);
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
            Group = mediaGroup.name;
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

      host.backups.jobs.${backupJob} = {
        preparations.pinepods-native-backup = {
          service = "pinepods-native-backup";
          title = "PinePods Native Backup";
          paths = [ backupDir ];
        };
      };

      host.internalService.services.pinepods = {
        enable = true;
        upstream = cfg.localUrl;
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
          assertion = instance ? dataDir && instance ? downloadsDir && instance ? mediaDir;
          message = "The PinePods inventory instance must define dataDir, downloadsDir, and mediaDir.";
        }
        {
          assertion = builtins.elem hostname mediaExport.clients;
          message = "The PinePods host must be an authorized media NFS client.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The PinePods host must be a declared backup client.";
        }
        {
          assertion = builtins.elem pinepodsSso.adminGroup administrator.groups;
          message = "The SSO administrator must belong to the PinePods admin group.";
        }
        {
          assertion = builtins.elem pinepodsSso.userGroup administrator.groups;
          message = "The SSO administrator must belong to the PinePods user group.";
        }
      ];
    })
  ];
}
