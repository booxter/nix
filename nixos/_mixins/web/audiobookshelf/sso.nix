{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.audiobookshelf;
  oidcCfg = cfg.oidc;
  service = hostInventory.servicesById.audiobookshelf;
  sso = hostInventory.sso.applications.audiobookshelf;
  oidcClient = config.host.sso.oidc.clients.audiobookshelf;
  oidcScopes = config.host.sso.oidc.baseScopes;
  settingsFile = (pkgs.formats.json { }).generate "audiobookshelf-oidc-settings.json" {
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
    # Keep local login at /login?autoLaunch=0 as a rollback path.
    authOpenIDAutoLaunch = true;
    authOpenIDAutoRegister = true;
    authOpenIDMatchExistingBy = "username";
    authOpenIDMobileRedirectURIs = [ "audiobookshelf://oauth" ];
    authOpenIDGroupClaim = "abs_groups";
    authOpenIDAdvancedPermsClaim = "";
    authOpenIDSubfolderForRedirectURLs = "";
  };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.tools.package "audiobookshelf-oidc-bootstrap")
    "--url"
    cfg.localUrl
    "--api-token-file"
    cfg.apiToken.file
    "--client-secret-file"
    oidcClient.secret.path
    "--settings-file"
    settingsFile
    "--restart-unit"
    "audiobookshelf.service"
  ];
in
{
  options.services.audiobookshelf.oidc.enable =
    lib.mkEnableOption "Audiobookshelf OpenID Connect authentication";

  config = lib.mkIf oidcCfg.enable {
    assertions = [
      {
        assertion = cfg.enable;
        message = "services.audiobookshelf.oidc requires services.audiobookshelf.enable.";
      }
    ];

    host.sso.oidc.registrations.audiobookshelf = {
      displayName = "Audiobookshelf";
      originUrls = [
        "${service.url}/auth/openid/callback"
        "${service.url}/auth/openid/mobile-redirect"
      ];
      originLanding = "${service.url}/";
      scopeMaps = {
        ${sso.adminGroup} = oidcScopes ++ [ "abs_groups" ];
        ${sso.userGroup} = oidcScopes ++ [ "abs_groups" ];
      };
      claimMaps.abs_groups.valuesByGroup = {
        ${sso.adminGroup} = [ "admin" ];
        ${sso.userGroup} = [ "user" ];
      };
      secret = {
        sopsKey = "audiobookshelf/oidc/client_secret";
        name = "audiobookshelf/oidc/client_secret";
        restartUnits = [ "audiobookshelf-oidc-bootstrap.service" ];
      };
    };

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
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = bootstrapCommand;
      };
    };
  };
}
