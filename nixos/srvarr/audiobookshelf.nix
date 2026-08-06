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
  port = 9292;
  stateDir = "${config.host.srvarrPaths.stateDir}/audiobookshelf";
  user = "audiobookshelf";
  audiobookshelfService = hostInventory.servicesById.audiobookshelf;
  oidcClient = config.host.sso.oidc.clients.audiobookshelf;
  oidcScopes = config.host.sso.oidc.baseScopes;
  backupSettingsFile = pkgs.writeText "audiobookshelf-backup-settings.json" (
    builtins.toJSON {
      backupSchedule = "15 4 * * *";
      backupsToKeep = 2;
      maxBackupSize = 1;
    }
  );
  oidcSettingsFile = pkgs.writeText "audiobookshelf-oidc-settings.json" (
    builtins.toJSON {
      authActiveAuthMethods = [
        "local"
        "openid"
      ];
      authOpenIDIssuerURL = oidcClient.issuerUrl;
      authOpenIDAuthorizationURL = oidcClient.authorizationUrl;
      authOpenIDTokenURL = oidcClient.tokenUrl;
      authOpenIDUserInfoURL = oidcClient.userinfoUrl;
      authOpenIDJwksURL = oidcClient.jwksUrl;
      authOpenIDLogoutURL = null;
      authOpenIDClientID = oidcClient.clientId;
      authOpenIDClientSecret = null;
      authOpenIDTokenSigningAlgorithm = "ES256";
      authOpenIDButtonText = "SSO";
      # Make SSO the normal browser recovery path after Audiobookshelf's
      # refresh token expires. Local login remains available with
      # /login?autoLaunch=0 for rollback.
      authOpenIDAutoLaunch = true;
      authOpenIDAutoRegister = true;
      authOpenIDMatchExistingBy = "username";
      authOpenIDMobileRedirectURIs = [ "audiobookshelf://oauth" ];
      authOpenIDGroupClaim = "abs_groups";
      authOpenIDAdvancedPermsClaim = "";
      authOpenIDSubfolderForRedirectURLs = "";
    }
  );
  oidcBootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' srvarrPkgs.audiobookshelf-tools "audiobookshelf-oidc-bootstrap")
    "--url"
    "http://127.0.0.1:${toString port}"
    "--api-token-file"
    config.sops.secrets."audiobookshelf/bootstrap/api_token".path
    "--client-secret-file"
    oidcClient.secret.path
    "--settings-file"
    oidcSettingsFile
    "--restart-unit"
    "audiobookshelf.service"
  ];
  backupBootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' srvarrPkgs.audiobookshelf-tools "audiobookshelf-backup-bootstrap")
    "--url"
    "http://127.0.0.1:${toString port}"
    "--credential-name"
    "api-token"
    "--settings-file"
    backupSettingsFile
  ];
in
{
  host.sso.oidc.registrations.audiobookshelf = {
    displayName = "Audiobookshelf";
    originUrls = [
      "${audiobookshelfService.url}/auth/openid/callback"
      "${audiobookshelfService.url}/auth/openid/mobile-redirect"
    ];
    originLanding = "${audiobookshelfService.url}/";
    scopeMaps = {
      "media-admins" = oidcScopes ++ [ "abs_groups" ];
      "media-users" = oidcScopes ++ [ "abs_groups" ];
    };
    claimMaps.abs_groups.valuesByGroup = {
      "media-admins" = [ "admin" ];
      "media-users" = [ "user" ];
    };
    secret = {
      sopsKey = "audiobookshelf/oidc/client_secret";
      name = "audiobookshelf/oidc/client_secret";
      restartUnits = [ "audiobookshelf-oidc-bootstrap.service" ];
    };
  };

  sops.secrets = {
    "audiobookshelf/bootstrap/api_token" = {
      mode = "0400";
      restartUnits = [
        "audiobookshelf-backup-bootstrap.service"
        "audiobookshelf-oidc-bootstrap.service"
      ];
    };
  };

  services.audiobookshelf = {
    enable = true;
    dataDir = stateDir;
    group = "media";
    port = port;
    user = user;
  };

  systemd.tmpfiles.rules = [
    "d '${stateDir}' 0700 ${user} root - -"
  ];

  # Upstream assumes dataDir lives under /var/lib; keep only the overrides
  # needed for the absolute state path we use on srvarr.
  systemd.services.audiobookshelf.serviceConfig.WorkingDirectory = lib.mkForce stateDir;

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

  systemd.services.audiobookshelf-oidc-bootstrap = {
    description = "Configure Audiobookshelf OIDC";
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
      ExecStart = oidcBootstrapCommand;
    };
  };

  systemd.services.audiobookshelf-backup-bootstrap = {
    description = "Enable Audiobookshelf native backups";
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
      DynamicUser = true;
      LoadCredential = "api-token:${config.sops.secrets."audiobookshelf/bootstrap/api_token".path}";
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ExecStart = backupBootstrapCommand;
    };
  };

  users.users.${user} = {
    home = lib.mkForce "/var/empty";
    uid = accounts.uids.audiobookshelf;
  };

  host.internalHttps.services.audiobookshelf = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
    publicAliases = [ audiobookshelfService.publicHost ];
    mtls.enable = true;
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
}
