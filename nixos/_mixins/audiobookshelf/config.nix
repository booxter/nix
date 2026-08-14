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
  libraries = builtins.attrValues model.libraries;
  readablePaths = map (library: library.media.path) (
    builtins.filter (library: library.media != null && library.access == "readOnly") libraries
  );
  writablePaths = map (library: library.media.path) (
    builtins.filter (library: library.media != null && library.access == "readWrite") libraries
  );
  claims = lib.unique (
    map (library: library.media.storage.claim) (
      builtins.filter (library: library.media != null) libraries
    )
  );
  app = model.ssoApplication;
  accessGroups = builtins.filter (group: group != null) [
    (if app == null then null else app.adminGroup)
    (if app == null then null else app.userGroup)
  ];
  groupScopes = lib.genAttrs accessGroups (_: model.oidcScopes ++ [ "abs_groups" ]);
  groupClaims =
    lib.optionalAttrs (app != null && app.adminGroup != null) {
      ${app.adminGroup} = [ "admin" ];
    }
    // lib.optionalAttrs (app != null && app.userGroup != null) {
      ${app.userGroup} = [ "user" ];
    };
  oidc = model.oidcClient;
  validLibraries = lib.filterAttrs (_: library: library.media != null) model.libraries;
  reconcilePackage = pkgs.callPackage ./package { };
  settingsFile = pkgs.writeText "audiobookshelf-reconcile.json" (
    builtins.toJSON {
      oidc = {
        authActiveAuthMethods = [
          "local"
          "openid"
        ];
        authOpenIDIssuerURL = oidc.issuerUrl;
        authOpenIDAuthorizationURL = oidc.authorizationUrl;
        authOpenIDTokenURL = oidc.tokenUrl;
        authOpenIDUserInfoURL = oidc.userinfoUrl;
        authOpenIDJwksURL = oidc.jwksUrl;
        authOpenIDLogoutURL = null;
        authOpenIDClientID = oidc.clientId;
        authOpenIDClientSecret = null;
        authOpenIDTokenSigningAlgorithm = "ES256";
        authOpenIDButtonText = "SSO";
        # Local login remains available at /login?autoLaunch=0 for rollback.
        authOpenIDAutoLaunch = true;
        authOpenIDAutoRegister = true;
        authOpenIDMatchExistingBy = "username";
        authOpenIDMobileRedirectURIs = [ "audiobookshelf://oauth" ];
        authOpenIDGroupClaim = "abs_groups";
        authOpenIDAdvancedPermsClaim = "";
        authOpenIDSubfolderForRedirectURLs = "";
      };
      backups = {
        backupSchedule = "15 4 * * *";
        backupsToKeep = 2;
        maxBackupSize = 1;
      };
      libraries = lib.mapAttrsToList (_: library: {
        name = library.displayName;
        path = library.media.path;
        mediaType = "book";
        audiobooksOnly = library.media.contentType == "audiobooks";
        inherit (library) icon provider;
      }) validLibraries;
    }
  );
  reconcileCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' reconcilePackage "audiobookshelf-reconcile")
    "--url"
    "http://127.0.0.1:${toString model.port}"
    "--api-token-credential"
    "api-token"
    "--client-secret-credential"
    "oidc-client-secret"
    "--settings-file"
    settingsFile
    "--restart-unit"
    "audiobookshelf.service"
  ];
in
{
  config = lib.mkIf (cfg != null) {
    services.audiobookshelf = {
      enable = true;
      package = pkgs.audiobookshelf;
      dataDir = cfg.stateDir;
      inherit (model) group port user;
    };

    users.users.${model.user} = {
      group = model.group;
      home = lib.mkForce "/var/empty";
      isSystemUser = true;
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${model.user} root - -"
    ];

    host.storage.claims = lib.mkMerge (
      map (claim: {
        ${claim}.attachments.audiobookshelf = { };
      }) claims
    );

    host.backups.sources.audiobookshelf = {
      title = "Audiobookshelf";
      paths = [ "${cfg.stateDir}/backups" ];
    };

    services.nginx.commonHttpConfig = ''
      map $http_x_forwarded_host $audiobookshelf_proxy_host {
          default $http_x_forwarded_host;
          "" $host;
      }

      map $http_x_forwarded_proto $audiobookshelf_proxy_proto {
          default $http_x_forwarded_proto;
          "" $scheme;
      }
    '';

    host.web.services.audiobookshelf = {
      enable = true;
      upstream = "http://127.0.0.1:${toString model.port}";
      public = {
        enable = true;
        hostName = cfg.publicHostName;
      };
      health.frontend = {
        enable = true;
        path = "";
      };
      observability.importance = "important";
      dashboard = {
        enable = true;
        section = "user";
      };
      internal = {
        recommendedProxySettings = false;
        locationExtraConfig = ''
          proxy_set_header Host $audiobookshelf_proxy_host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $audiobookshelf_proxy_proto;
          proxy_set_header X-Forwarded-Host $audiobookshelf_proxy_host;
          proxy_set_header X-Forwarded-Server $hostname;
        '';
      };
      auth = {
        mode = "oidc";
        oidcRegistration = {
          displayName = "Audiobookshelf";
          originUrls = [
            "${model.service.public.url}/auth/openid/callback"
            "${model.service.public.url}/auth/openid/mobile-redirect"
          ];
          originLanding = "${model.service.public.url}/";
          scopeMaps = groupScopes;
          claimMaps.abs_groups.valuesByGroup = groupClaims;
          secret = {
            sopsKey = "audiobookshelf/oidc/client_secret";
            name = "audiobookshelf/oidc/client_secret";
            restartUnits = [ "audiobookshelf-reconcile.service" ];
          };
        };
      };
    };

    sops.secrets."audiobookshelf/bootstrap/api_token" = {
      key = "audiobookshelf/bootstrap/api_token";
      mode = "0400";
      restartUnits = [ "audiobookshelf-reconcile.service" ];
    };

    systemd.services = {
      # Upstream assumes dataDir lives under /var/lib. An absolute
      # StateDirectory is ignored by systemd, so retain only settings that work
      # for arbitrary state paths.
      audiobookshelf.serviceConfig = {
        StateDirectory = lib.mkForce null;
        WorkingDirectory = lib.mkForce cfg.stateDir;
        ReadOnlyPaths = readablePaths;
        ReadWritePaths = [ cfg.stateDir ] ++ writablePaths;
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };

      audiobookshelf-reconcile = {
        description = "Reconcile Audiobookshelf settings and libraries";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "audiobookshelf.service"
          "sops-install-secrets.service"
        ];
        after = [
          "audiobookshelf.service"
          "sops-install-secrets.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          LoadCredential = [
            "api-token:${config.sops.secrets."audiobookshelf/bootstrap/api_token".path}"
            "oidc-client-secret:${oidc.secret.path}"
          ];
          ExecStart = reconcileCommand;
          CapabilityBoundingSet = "";
          LockPersonality = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "strict";
          RemoveIPC = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
        };
      };
    };
  };
}
