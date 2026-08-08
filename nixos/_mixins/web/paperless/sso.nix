{
  config,
  hostInventory,
  lib,
  ...
}:
let
  ssoAdministrator = hostInventory.sso.administrator;
  paperlessSso = hostInventory.sso.applications.paperless;
  paperlessService = hostInventory.servicesById.paperless;
  isLocal = hostInventory.serviceRunsOn config.networking.hostName paperlessService;
  oidcClient = config.host.sso.oidc.clients.paperless;
  oidcScopes = config.host.sso.oidc.baseScopes;
  providerId = "sso";
  clientSecretPlaceholder = "__PAPERLESS_OIDC_CLIENT_SECRET__";
  providersJson =
    builtins.replaceStrings [ clientSecretPlaceholder ] [ oidcClient.secret.placeholder ]
      (
        builtins.toJSON {
          openid_connect.APPS = [
            {
              provider_id = providerId;
              name = "SSO";
              client_id = oidcClient.clientId;
              secret = clientSecretPlaceholder;
              settings = {
                email_authentication = true;
                oauth_pkce_enabled = true;
                server_url = oidcClient.discoveryUrl;
                token_auth_method = "client_secret_basic";
                verified_email = true;
                scope = oidcScopes ++ [ "groups" ];
              };
            }
          ];
        }
      );
in
{
  config = lib.mkIf isLocal {
    assertions = [
      {
        assertion =
          builtins.elem paperlessSso.adminGroup
            hostInventory.sso.users.${ssoAdministrator}.groups;
        message = "The SSO administrator must belong to the Paperless admin group.";
      }
    ];

    host.sso.oidc.registrations.paperless = {
      displayName = "Paperless";
      originUrls = [ "${paperlessService.url}/accounts/oidc/sso/login/callback/" ];
      originLanding = "${paperlessService.url}/";
      scopeMaps = {
        ${paperlessSso.adminGroup} = oidcScopes ++ [ "groups" ];
        ${paperlessSso.userGroup} = oidcScopes ++ [ "groups" ];
      };
      claimMaps.groups.valuesByGroup = {
        ${paperlessSso.adminGroup} = [ paperlessSso.adminGroup ];
        ${paperlessSso.userGroup} = [ paperlessSso.userGroup ];
      };
      secret = {
        sopsKey = "paperless/oidc/client_secret";
        name = "paperless/oidc/client_secret";
        restartUnits = [
          "paperless-scheduler.service"
          "paperless-task-queue.service"
          "paperless-web.service"
        ];
      };
    };

    sops.templates."paperless-oidc.env" = {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
      content = ''
        PAPERLESS_SOCIALACCOUNT_PROVIDERS='${providersJson}'
      '';
      restartUnits = [
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-web.service"
      ];
    };

    services.paperless = {
      environmentFile = config.sops.templates."paperless-oidc.env".path;
      settings = {
        PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
        PAPERLESS_DISABLE_REGULAR_LOGIN = false;
        PAPERLESS_REDIRECT_LOGIN_TO_SSO = false;
        PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = false;
        PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS = true;
        PAPERLESS_SOCIAL_AUTO_SIGNUP = false;
      };
    };
  };
}
