{ lib, hostInventory }:
let
  idService = hostInventory.servicesById.id;
  lan = hostInventory.site.lan;
  issuerBaseUrl = "https://${idService.publicHost}";
  baseScopes = [
    "openid"
    "email"
    "profile"
  ];
  openidBaseUrl = clientId: "${issuerBaseUrl}/oauth2/openid/${clientId}";
  discoveryUrl = clientId: "${openidBaseUrl clientId}/.well-known/openid-configuration";
  userinfoUrl = clientId: "${openidBaseUrl clientId}/userinfo";
  jwksUrl = clientId: "${openidBaseUrl clientId}/public_key.jwk";
  authorizationUrl = "${issuerBaseUrl}/ui/oauth2";
  tokenUrl = "${issuerBaseUrl}/oauth2/token";
  serviceUrl = serviceId: hostInventory.servicesById.${serviceId}.url;
  scopeWith = extraScopes: baseScopes ++ extraScopes;
  clientSecretKey = clientId: "kanidm/oauth2/${clientId}/client_secret";
  mkClient =
    clientId: client:
    {
      inherit clientId;
      secretKey = clientSecretKey clientId;
      preferShortUsername = true;
    }
    // client;

  srvarrAdminAppHosts = lib.unique (
    lib.concatMap hostInventory.toInternalHttpsServiceHosts hostInventory.srvarrAdminAppIds
  );
in
rec {
  inherit
    authorizationUrl
    baseScopes
    clientSecretKey
    discoveryUrl
    issuerBaseUrl
    jwksUrl
    openidBaseUrl
    scopeWith
    tokenUrl
    userinfoUrl
    ;

  clients = {
    grafana = mkClient "grafana" {
      displayName = "Grafana";
      originUrl = "https://grafana.${lan.domain}/login/generic_oauth";
      originLanding = "https://grafana.${lan.domain}/";
      scopeMaps = {
        "grafana-admins" = baseScopes;
        "grafana-viewers" = baseScopes;
      };
      claimMaps.grafana_role.valuesByGroup = {
        "grafana-admins" = [ "admin" ];
        "grafana-viewers" = [ "viewer" ];
      };
    };

    vikunja = mkClient "vikunja" {
      displayName = "Vikunja";
      originUrl = "${serviceUrl "vikunja"}/auth/openid/sso";
      originLanding = "${serviceUrl "vikunja"}/";
      allowInsecureClientDisablePkce = true;
      scopeMaps."vikunja-users" = baseScopes;
    };

    open-webui = mkClient "open-webui" {
      displayName = "Open WebUI";
      originUrl = "${serviceUrl "ai"}/oauth/oidc/login/callback";
      originLanding = "${serviceUrl "ai"}/";
      scopeMaps."ai-users" = baseScopes;
      claimMaps.open_webui_role.valuesByGroup = {
        "ai-users" = [ "user" ];
        "sso-admins" = [ "admin" ];
      };
    };

    search = mkClient "search" {
      displayName = "Search";
      originUrl = "${serviceUrl "search"}/oauth2/callback";
      originLanding = "${serviceUrl "search"}/";
      scopeMaps."ai-users" = scopeWith [ "ai_groups" ];
      claimMaps.ai_groups.valuesByGroup."ai-users" = [ "ai-users" ];
    };

    litellm = mkClient "litellm" {
      displayName = "LiteLLM";
      originUrl = "${serviceUrl "llm"}/sso/callback";
      originLanding = "${serviceUrl "llm"}/ui/";
      scopeMaps."infra-admins" = scopeWith [ "litellm_groups" ];
      claimMaps.litellm_groups.valuesByGroup."infra-admins" = [ "infra-admins" ];
    };

    paperless = mkClient "paperless" {
      displayName = "Paperless";
      originUrl = "${serviceUrl "paperless"}/accounts/oidc/sso/login/callback/";
      originLanding = "${serviceUrl "paperless"}/";
      scopeMaps = {
        "paperless-admins" = scopeWith [ "groups" ];
        "paperless-users" = scopeWith [ "groups" ];
      };
      claimMaps.groups.valuesByGroup = {
        "paperless-admins" = [ "paperless-admins" ];
        "paperless-users" = [ "paperless-users" ];
      };
    };

    romm = mkClient "romm" {
      displayName = "RomM";
      originUrl = "${serviceUrl "romm"}/api/oauth/openid";
      originLanding = "${serviceUrl "romm"}/";
      allowInsecureClientDisablePkce = true;
      scopeMaps = {
        "romm-admins" = scopeWith [ "romm_roles" ];
        "romm-editors" = scopeWith [ "romm_roles" ];
        "romm-viewers" = scopeWith [ "romm_roles" ];
      };
      claimMaps.romm_roles.valuesByGroup = {
        "romm-admins" = [ "romm-admins" ];
        "romm-editors" = [ "romm-editors" ];
        "romm-viewers" = [ "romm-viewers" ];
      };
    };

    audiobookshelf = mkClient "audiobookshelf" {
      displayName = "Audiobookshelf";
      originUrl = [
        "${serviceUrl "audiobookshelf"}/auth/openid/callback"
        "${serviceUrl "audiobookshelf"}/auth/openid/mobile-redirect"
      ];
      originLanding = "${serviceUrl "audiobookshelf"}/";
      scopeMaps = {
        "media-admins" = scopeWith [ "abs_groups" ];
        "media-users" = scopeWith [ "abs_groups" ];
      };
      claimMaps.abs_groups.valuesByGroup = {
        "media-admins" = [ "admin" ];
        "media-users" = [ "user" ];
      };
    };

    aurral = mkClient "aurral" {
      displayName = "Aurral";
      originUrl = "${serviceUrl "aurral"}/oauth2/callback";
      originLanding = "${serviceUrl "aurral"}/";
      scopeMaps = {
        "media-admins" = scopeWith [ "media_groups" ];
        "media-users" = scopeWith [ "media_groups" ];
      };
      claimMaps.media_groups.valuesByGroup = {
        "media-admins" = [ "media-admins" ];
        "media-users" = [ "media-users" ];
      };
    };

    shelfmark = mkClient "shelfmark" {
      displayName = "Shelfmark";
      originUrl = "${serviceUrl "shelfmark"}/api/auth/oidc/callback";
      originLanding = "${serviceUrl "shelfmark"}/";
      scopeMaps = {
        "media-admins" = scopeWith [ "media_groups" ];
        "media-users" = scopeWith [ "media_groups" ];
      };
      claimMaps.media_groups.valuesByGroup = {
        "media-admins" = [ "media-admins" ];
        "media-users" = [ "media-users" ];
      };
    };

    srvarr-admin-apps = mkClient "srvarr-admin-apps" {
      displayName = "srvarr admin apps";
      originUrl = map (host: "https://${host}/oauth2/callback") srvarrAdminAppHosts;
      originLanding = "https://bazarr.${lan.domain}/";
      scopeMaps."infra-admins" = scopeWith [ "infra_groups" ];
      claimMaps.infra_groups.valuesByGroup."infra-admins" = [ "infra-admins" ];
    };
  };

  kanidmProvisionClients =
    secretPathFor:
    lib.mapAttrs (
      _: client:
      {
        inherit (client)
          displayName
          originLanding
          originUrl
          preferShortUsername
          scopeMaps
          ;
      }
      // lib.optionalAttrs (client ? allowInsecureClientDisablePkce) {
        inherit (client) allowInsecureClientDisablePkce;
      }
      // lib.optionalAttrs (client ? claimMaps) { inherit (client) claimMaps; }
      // {
        basicSecretFile = secretPathFor client.clientId;
      }
    ) clients;
}
