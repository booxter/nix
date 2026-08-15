{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg selected;
  adminGroup = if model.ssoApplication == null then null else model.ssoApplication.roles.admin;
  adminUsers = lib.attrNames (
    lib.filterAttrs (
      _: person: adminGroup != null && builtins.elem adminGroup person.groups
    ) config.host.sso.users
  );
  browserOrigin = "https://${cfg.publicHostName}";
  allowedGroups =
    if model.ssoApplication == null then [ ] else builtins.attrValues model.ssoApplication.roles;
  cacheZone = "aurral_images";
  cacheLocation = {
    proxyPass = "http://127.0.0.1:${toString model.port}";
    recommendedProxySettings = true;
    extraConfig = ''
      proxy_cache ${cacheZone};
      proxy_cache_background_update on;
      proxy_cache_lock on;
      proxy_cache_revalidate on;
      proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
    '';
  };
  imageLocations."^~ /api/image-proxy/" = cacheLocation;
in
{
  config = lib.mkIf (cfg != null) {
    fonts.packages = [ pkgs.dejavu_fonts ];

    users.groups.${model.user} = { };
    users.users.${model.user} = {
      isSystemUser = true;
      group = model.user;
      extraGroups = lib.unique [
        model.group
        selected.group
      ];
    };

    sops.templates."aurral-slskd.env" = {
      owner = model.user;
      group = model.user;
      mode = "0400";
      restartUnits = [ "aurral.service" ];
      content = ''
        AURRAL_SLSKD_API_KEY=${config.sops.placeholder."${selected.secretPrefix}/web/apiKey"}
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${model.user} ${model.user} - -"
      "z ${cfg.stateDir} 0750 ${model.user} ${model.user} - -"
      "d /var/cache/nginx/aurral-images 0750 nginx nginx - -"
    ];

    host.storage.claims.${cfg.storageClaim} = {
      directories.${model.flowRelativePath} = {
        group = model.group;
        mode = "2775";
      };
      attachments.aurral = { };
    };

    host.backups.sources.aurral-database = {
      title = "Aurral";
      database = {
        type = "sqlite";
        path = "${cfg.stateDir}/aurral.db";
        stagingDir = "${cfg.stateDir}-backup/latest";
      };
    };

    host.web.services.aurral = {
      upstream = "http://127.0.0.1:${toString model.port}";
      public = {
        hostName = cfg.publicHostName;
        locationExtraConfig = ''
          proxy_set_header X-Forwarded-For $remote_addr;
        '';
      };
      health = {
        frontend = {
          path = "/oauth2/sign_in";
        };
        backend = {
          path = "/api/health/live";
        };
      };
      observability.importance = "important";
      dashboard = {
        section = "user";
      };
      auth = {
        oauth2ProxyGate = {
          displayName = "Aurral";
          port = 4181;
          inherit allowedGroups;
          groupClaim = "media_groups";
          externalOrigin = browserOrigin;
          internalHttpsServiceNames = [ "aurral" ];
          authRequestHeaders = {
            X-Forwarded-User = "x_auth_request_preferred_username";
            X-Forwarded-Email = "x_auth_request_email";
            X-Forwarded-Groups = "x_auth_request_groups";
          };
          sessionRefresh = {
            intervalSeconds = 14 * 60;
            lifetimeSeconds = 8 * 60 * 60;
          };
        };
      };
    };

    services.nginx = {
      proxyCachePath.aurral-images = {
        enable = true;
        keysZoneName = cacheZone;
        keysZoneSize = "1m";
        inactive = "7d";
        maxSize = "256m";
      };
      virtualHosts = {
        "internal-https-aurral".locations = imageLocations;
        ${cfg.publicHostName}.locations = imageLocations;
      };
    };

    systemd.services.aurral = {
      description = "Aurral music discovery and flow download service";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        Wants = [ "network-online.target" ];
        After = [
          "network-online.target"
          "${selected.unitName}.service"
        ];
        Requires = [ "${selected.unitName}.service" ];
      };
      path = [
        pkgs.coreutils
        pkgs.ffmpeg
        pkgs.yt-dlp
      ];
      environment = {
        AURRAL_DATA_DIR = cfg.stateDir;
        DOWNLOAD_FOLDER = model.flowDir;
        WEEKLY_FLOW_FOLDER = model.flowDir;
        PORT = toString model.port;
        TRUST_PROXY = "2";
        AURRAL_SLSKD_MANAGED = "true";
        AURRAL_SLSKD_URL = selected.apiUrl;
        AURRAL_SLSKD_PRIORITY = "10";
        AURRAL_SLSKD_PREFERRED_FORMAT = "flac";
        AURRAL_SLSKD_STRICT_FORMAT = "false";
        AURRAL_SLSKD_CLEANUP_AFTER_RUNS = "true";
        AUTH_PROXY_ENABLED = "true";
        AUTH_PROXY_HEADER = "x-forwarded-user";
        AUTH_PROXY_ADMIN_USERS = lib.concatStringsSep "," adminUsers;
        AUTH_PROXY_DEFAULT_ROLE = "user";
        AUTH_PROXY_TRUSTED_IPS = "127.0.0.1,::1";
        DISABLE_LOCAL_AUTH = "true";
      };
      serviceConfig = {
        ExecStart = lib.getExe (pkgs.callPackage ./package { });
        EnvironmentFile = [ config.sops.templates."aurral-slskd.env".path ];
        User = model.user;
        Group = model.user;
        WorkingDirectory = cfg.stateDir;
        UMask = "0007";
        Restart = "on-failure";
        RestartSec = "5s";
        LimitNOFILE = 65536;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          cfg.stateDir
          model.flowDir
          selected.completedDir
        ];
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
  };
}
