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
  oidc = model.oidcClient;
  reconcilePackage = pkgs.callPackage ./package { };
  validLibraries = lib.filterAttrs (_: library: library.media != null) model.libraries;
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
  command = utils.escapeSystemdExecArgs [
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
    sops.secrets."audiobookshelf/bootstrap/api_token" = {
      key = "audiobookshelf/bootstrap/api_token";
      mode = "0400";
      restartUnits = [ "audiobookshelf-reconcile.service" ];
    };

    systemd.services.audiobookshelf-reconcile = {
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
        ExecStart = command;
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
}
