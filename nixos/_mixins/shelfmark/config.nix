{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  app = model.ssoApplication;
  accessGroups = builtins.filter (group: group != null) [
    (if app == null then null else app.adminGroup)
    (if app == null then null else app.userGroup)
  ];
  groupScopes = lib.genAttrs accessGroups (_: model.oidcScopes ++ [ "shelfmark_groups" ]);
  groupClaims = lib.genAttrs accessGroups (group: [ group ]);
  torrentEnvironment = lib.optionalAttrs (model.torrent != null) {
    PROWLARR_TORRENT_CLIENT = model.torrent.client.implementation;
    TRANSMISSION_URL = model.torrent.client.endpoint;
    TRANSMISSION_CATEGORY = model.torrent.label;
    TRANSMISSION_DOWNLOAD_DIR = model.torrent.path;
  };
  usenetEnvironment = lib.optionalAttrs (model.usenet != null) {
    PROWLARR_USENET_CLIENT = model.usenet.client.implementation;
    SABNZBD_URL = model.usenet.client.endpoint;
    SABNZBD_CATEGORY = model.usenet.category;
  };
  converterPackage = import ./ebook-converter { inherit pkgs; };
  converterEnvironment = {
    CUSTOM_SCRIPT = "${converterPackage}/bin/shelfmark-ebook-converter-hook";
    CUSTOM_SCRIPT_JSON_PAYLOAD = "true";
    CUSTOM_SCRIPT_PATH_MODE = "absolute";
    EBOOK_CONVERTER_LIBRARY_ROOT = model.ebooks.path;
    EBOOK_CONVERTER_STATE_DIR = model.converter.stateDir;
  };
  sabnzbdSecret = if model.usenet == null then null else model.usenet.client.authentication.secret;
  writablePaths = lib.unique (
    [
      cfg.stateDir
      model.ebooks.path
      model.converter.stateDir
    ]
    ++ lib.optional (model.audiobooks != null) model.audiobooks.path
    ++ lib.optional (model.torrent != null) model.torrent.path
    ++ lib.optional (model.usenet != null) model.usenet.path
  );
  storageClaims = lib.unique (
    map (item: item.storage.claim) (
      builtins.filter (item: item != null) [
        model.ebooks
        model.audiobooks
        model.torrent
        model.usenet
      ]
    )
  );
  ebookConverter = {
    package = converterPackage;
    library = model.ebooks;
    stateDir = model.converter.stateDir;
    user = "ebook-converter";
    group = "media";
    metricsDir = "/var/lib/prometheus-node-exporter-textfile";
    metricsFile = "/var/lib/prometheus-node-exporter-textfile/ebook-converter.prom";
  };
in
{
  config = lib.mkIf (cfg != null) {
    services.shelfmark = {
      enable = true;
      package = pkgs.shelfmark;
      environment = {
        AUTH_METHOD = "oidc";
        CONFIG_DIR = cfg.stateDir;
        DISABLE_LOCAL_AUTH = "true";
        FLASK_HOST = "127.0.0.1";
        FLASK_PORT = model.port;
        HIDE_LOCAL_AUTH = "true";
        INGEST_DIR = model.ebooks.path;
        OIDC_ADMIN_GROUP = model.ssoApplication.adminGroup;
        OIDC_AUTO_PROVISION = "true";
        OIDC_BUTTON_LABEL = "SSO";
        OIDC_CLIENT_ID = model.oidcClient.clientId;
        OIDC_DISCOVERY_URL = model.oidcClient.discoveryUrl;
        OIDC_GROUP_CLAIM = "shelfmark_groups";
        OIDC_SCOPES = lib.concatStringsSep "," (model.oidcScopes ++ [ "shelfmark_groups" ]);
        OIDC_USE_ADMIN_GROUP = "true";
        SESSION_COOKIE_SECURE = "true";
      }
      // lib.optionalAttrs (model.audiobooks != null) {
        DESTINATION_AUDIOBOOK = model.audiobooks.path;
      }
      // lib.optionalAttrs (model.audiobookshelfService != null) {
        AUDIOBOOK_LIBRARY_URL = model.audiobookshelfService.public.url;
      }
      // torrentEnvironment
      // usenetEnvironment
      // converterEnvironment;
    };

    users.users = {
      ${model.user} = {
        group = model.group;
        home = "/var/empty";
        isSystemUser = true;
      };
      ${ebookConverter.user} = {
        group = ebookConverter.group;
        home = "/var/empty";
        isSystemUser = true;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${model.user} root - -"
      "d '${ebookConverter.stateDir}' 0770 ${ebookConverter.user} ${ebookConverter.group} - -"
      "z '${ebookConverter.stateDir}' 0770 ${ebookConverter.user} ${ebookConverter.group} - -"
      "z ${ebookConverter.metricsDir} 0775 root ${ebookConverter.group} - -"
    ];

    host.storage.claims = lib.mkMerge (
      (map (claim: {
        ${claim}.attachments.shelfmark.unit = "shelfmark";
      }) storageClaims)
      ++ [
        {
          ${ebookConverter.library.storage.claim}.attachments.ebook-converter.unit = "ebook-converter";
        }
      ]
    );

    host.backups.sources.shelfmark = {
      title = "Shelfmark";
      paths = [ "${cfg.stateDir}/plugins" ];
      capture = {
        type = "sqlite";
        database = {
          path = "${cfg.stateDir}/users.db";
          destinationDir = "${cfg.stateDir}-backup/latest";
          extraCopies = [
            {
              source = "${cfg.stateDir}/.flask_secret";
              mode = "0600";
              optional = false;
            }
            {
              source = "${cfg.stateDir}/settings.json";
              optional = false;
            }
          ];
        };
      };
    };

    host.web.services.shelfmark = {
      enable = true;
      upstream = "http://127.0.0.1:${toString model.port}";
      public = {
        enable = true;
        hostName = cfg.publicHostName;
      };
      health.frontend = {
        enable = true;
        path = "/api/health";
      };
      observability.importance = "important";
      dashboard = {
        enable = true;
        section = "user";
      };
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host ${cfg.publicHostName};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host ${cfg.publicHostName};
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };
      auth = {
        mode = "oidc";
        oidcRegistration = {
          displayName = "Shelfmark";
          originUrls = [ "${model.shelfmarkService.public.url}/api/auth/oidc/callback" ];
          originLanding = "${model.shelfmarkService.public.url}/";
          scopeMaps = groupScopes;
          claimMaps.shelfmark_groups.valuesByGroup = groupClaims;
          secret = {
            sopsKey = "shelfmark/oidc/client_secret";
            name = "shelfmark/oidc/client_secret";
            restartUnits = [ "shelfmark.service" ];
          };
        };
      };
    };

    sops.templates."shelfmark.env" = {
      owner = model.user;
      group = model.group;
      mode = "0400";
      content = ''
        OIDC_CLIENT_SECRET=${model.oidcClient.secret.placeholder}
      ''
      + lib.optionalString (sabnzbdSecret != null) ''
        SABNZBD_API_KEY=${builtins.getAttr sabnzbdSecret config.sops.placeholder}
      '';
      restartUnits = [ "shelfmark.service" ];
    };

    systemd.services = {
      shelfmark = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        serviceConfig = {
          EnvironmentFile = config.sops.templates."shelfmark.env".path;
          Group = model.group;
          ReadWritePaths = writablePaths;
          StateDirectory = lib.mkForce "";
          UMask = lib.mkForce "0002";
          User = model.user;
        };
      };

      ebook-converter = {
        description = "Convert library MOBI and AZW3 files to EPUB";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = utils.escapeSystemdExecArgs [
            (lib.getExe ebookConverter.package)
            "--library-root"
            ebookConverter.library.path
            "--lock-root"
            ebookConverter.stateDir
            "--state-file"
            "${ebookConverter.stateDir}/state.json"
            "--metrics-file"
            ebookConverter.metricsFile
            "--interval-seconds"
            "30"
            "--settle-seconds"
            "30"
            "--max-attempts"
            "3"
          ];
          Environment = "XDG_CONFIG_HOME=${ebookConverter.stateDir}";
          User = ebookConverter.user;
          Group = ebookConverter.group;
          UMask = "0002";
          Restart = "always";
          RestartSec = "10s";
          Nice = 10;
          IOSchedulingClass = "idle";
          CPUQuota = "200%";
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectHostname = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          LockPersonality = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          RestrictAddressFamilies = [ "AF_UNIX" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          RemoveIPC = true;
          ReadWritePaths = [
            ebookConverter.library.path
            ebookConverter.stateDir
            ebookConverter.metricsDir
          ];
        };
      };
    };
  };
}
