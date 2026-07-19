{ lib, hostInventory }:
let
  idService = hostInventory.servicesById.id;
  homeAssistantSso = hostInventory.sso.applications.home-assistant;
  pinepodsSso = hostInventory.sso.applications.pinepods;
  rommSso = hostInventory.sso.applications.romm;
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
  proxmoxLabHostSpecs = builtins.filter (
    spec: (spec.hostKind or null) == "proxmox" && !(spec.isWork or false)
  ) hostInventory.nixosHostSpecs;
  proxmoxLabHosts = lib.unique (
    lib.concatMap hostInventory.toNixosHostCertificateDnsNames proxmoxLabHostSpecs
  );
  proxmoxCanonicalHost = "proxmox.${lan.domain}";
  proxmoxOriginUrls = lib.unique (
    [
      "https://${proxmoxCanonicalHost}"
      "https://proxmox"
    ]
    ++ map (host: "https://${host}") proxmoxLabHosts
  );
  mkClient =
    clientId: client:
    {
      inherit clientId;
      allowInsecureClientDisablePkce = false;
      claimMaps = { };
      public = false;
      enableLocalhostRedirects = false;
      enableLegacyCrypto = false;
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

    home-assistant = mkClient "home-assistant" {
      displayName = "Home Assistant";
      public = true;
      originUrl = [
        "https://home.${lan.domain}/auth/oidc/welcome"
        "https://home.${lan.domain}/auth/oidc/callback"
      ];
      originLanding = "https://home.${lan.domain}/";
      scopeMaps = {
        ${homeAssistantSso.adminGroup} = scopeWith [ "home_groups" ];
        ${homeAssistantSso.userGroup} = scopeWith [ "home_groups" ];
      };
      claimMaps.home_groups.valuesByGroup = {
        ${homeAssistantSso.adminGroup} = [ homeAssistantSso.adminGroup ];
        ${homeAssistantSso.userGroup} = [ homeAssistantSso.userGroup ];
      };
    };

    vikunja = mkClient "vikunja" {
      displayName = "Vikunja";
      originUrl = "${serviceUrl "vikunja"}/auth/openid/sso";
      originLanding = "${serviceUrl "vikunja"}/";
      allowInsecureClientDisablePkce = true;
      scopeMaps."vikunja-users" = baseScopes;
    };

    trilium = mkClient "trilium" {
      displayName = "Trilium Notes";
      enableLegacyCrypto = true;
      originUrl = "${serviceUrl "notes"}/callback";
      originLanding = "${serviceUrl "notes"}/";
      scopeMaps."trilium-users" = baseScopes;
    };

    open-webui = mkClient "open-webui" {
      displayName = "Open WebUI";
      originUrl = "${serviceUrl "ai"}/oauth/oidc/login/callback";
      originLanding = "${serviceUrl "ai"}/";
      scopeMaps."ai-users" = scopeWith [ "open_webui_groups" ];
      claimMaps = {
        open_webui_groups.valuesByGroup."paperless-users" = [ "paperless-users" ];
        open_webui_role.valuesByGroup = {
          "ai-users" = [ "user" ];
          "sso-admins" = [ "admin" ];
        };
      };
    };

    search = mkClient "search" {
      displayName = "Search";
      originUrl = "${serviceUrl "search"}/oauth2/callback";
      originLanding = "${serviceUrl "search"}/";
      scopeMaps = {
        "ai-users" = scopeWith [ "ai_groups" ];
        "search-probe-users" = scopeWith [ "ai_groups" ];
      };
      claimMaps.ai_groups.valuesByGroup = {
        "ai-users" = [ "ai-users" ];
        "search-probe-users" = [ "search-probe-users" ];
      };
    };

    tg = mkClient "tg" {
      displayName = "Telegram Archive";
      originUrl = "https://tg.${lan.domain}/oauth2/callback";
      originLanding = "https://tg.${lan.domain}/";
      scopeMaps."infra-admins" = scopeWith [ "infra_groups" ];
      claimMaps.infra_groups.valuesByGroup."infra-admins" = [ "infra-admins" ];
    };

    oidc-synthetic-probe = mkClient "oidc-synthetic-probe" {
      displayName = "OIDC synthetic probe";
      public = true;
      enableLocalhostRedirects = true;
      originUrl = "http://127.0.0.1:9/oidc-synthetic-probe/callback";
      originLanding = issuerBaseUrl;
      scopeMaps."oidc-probe-users" = baseScopes;
    };

    proxmox = mkClient "proxmox" {
      displayName = "Proxmox VE";
      originUrl = proxmoxOriginUrls;
      originLanding = "https://${proxmoxCanonicalHost}/";
      scopeMaps."infra-admins" = scopeWith [ "infra_groups" ];
      claimMaps.infra_groups.valuesByGroup."infra-admins" = [ "infra-admins" ];
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

    paperless-gpt = mkClient "paperless-gpt" {
      displayName = "Paperless GPT";
      originUrl = "https://paperless-gpt.${lan.domain}/oauth2/callback";
      originLanding = "https://paperless-gpt.${lan.domain}/";
      scopeMaps."paperless-admins" = scopeWith [ "paperless_groups" ];
      claimMaps.paperless_groups.valuesByGroup."paperless-admins" = [ "paperless-admins" ];
    };

    romm = mkClient "romm" {
      displayName = "RomM";
      originUrl = "${serviceUrl "romm"}/api/oauth/openid";
      originLanding = "${serviceUrl "romm"}/";
      allowInsecureClientDisablePkce = true;
      scopeMaps = {
        ${rommSso.adminGroup} = scopeWith [ "romm_roles" ];
        ${rommSso.editorGroup} = scopeWith [ "romm_roles" ];
        ${rommSso.viewerGroup} = scopeWith [ "romm_roles" ];
      };
      claimMaps.romm_roles.valuesByGroup = {
        ${rommSso.adminGroup} = [ rommSso.adminGroup ];
        ${rommSso.editorGroup} = [ rommSso.editorGroup ];
        ${rommSso.viewerGroup} = [ rommSso.viewerGroup ];
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

    pinepods = mkClient "pinepods" {
      displayName = "PinePods";
      originUrl = "${serviceUrl "pinepods"}/api/auth/callback";
      originLanding = "${serviceUrl "pinepods"}/";
      # PinePods 0.9.0 explicitly requires a confidential client without PKCE.
      allowInsecureClientDisablePkce = true;
      scopeMaps = {
        ${pinepodsSso.adminGroup} = scopeWith [ "pinepods_roles" ];
        ${pinepodsSso.userGroup} = scopeWith [ "pinepods_roles" ];
      };
      claimMaps.pinepods_roles.valuesByGroup = {
        ${pinepodsSso.adminGroup} = [ "admin" ];
        ${pinepodsSso.userGroup} = [ "user" ];
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

    jfstat = mkClient "jfstat" {
      displayName = "Jellystat";
      originUrl = "https://jfstat.${lan.domain}/oauth2/callback";
      originLanding = "https://jfstat.${lan.domain}/";
      scopeMaps."media-admins" = scopeWith [ "media_groups" ];
      claimMaps.media_groups.valuesByGroup."media-admins" = [ "media-admins" ];
    };

    watchstate = mkClient "watchstate" {
      displayName = "WatchState";
      originUrl = "https://watchstate.${lan.domain}/oauth2/callback";
      originLanding = "https://watchstate.${lan.domain}/";
      scopeMaps."media-admins" = scopeWith [ "media_groups" ];
      claimMaps.media_groups.valuesByGroup."media-admins" = [ "media-admins" ];
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
      scopeMaps."media-admins" = scopeWith [ "media_groups" ];
      claimMaps.media_groups.valuesByGroup."media-admins" = [ "media-admins" ];
    };
  };

  kanidmProvisionClients =
    secretPathFor:
    lib.mapAttrs (_: client: {
      inherit (client)
        allowInsecureClientDisablePkce
        claimMaps
        displayName
        enableLocalhostRedirects
        enableLegacyCrypto
        originLanding
        originUrl
        preferShortUsername
        public
        scopeMaps
        ;
      basicSecretFile = if client.public then null else secretPathFor client.clientId;
    }) clients;
}
