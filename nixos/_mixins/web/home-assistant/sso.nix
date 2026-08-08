{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  service = hostInventory.servicesById.home;
  isLocal = hostInventory.serviceRunsOn config.networking.hostName service;
  serviceUrl = "https://${service.internalEndpointName}.${hostInventory.site.lan.domain}";
  sso = hostInventory.sso.applications.home-assistant;
  administratorName = hostInventory.sso.administrator;
  administrator = hostInventory.sso.users.${administratorName};
  oidcClient = config.host.sso.oidc.clients.home-assistant;
  oidcScopes = config.host.sso.oidc.baseScopes;
in
{
  config = lib.mkIf isLocal {
    assertions = [
      {
        assertion = builtins.elem sso.adminGroup administrator.groups;
        message = "The SSO administrator must belong to the Home Assistant admin group.";
      }
      {
        assertion = builtins.elem sso.userGroup administrator.groups;
        message = "The SSO administrator must belong to the Home Assistant user group.";
      }
    ];

    host.sso.oidc.registrations.home-assistant = {
      displayName = "Home Assistant";
      public = true;
      originUrls = [
        "${serviceUrl}/auth/oidc/welcome"
        "${serviceUrl}/auth/oidc/callback"
      ];
      originLanding = "${serviceUrl}/";
      scopeMaps = {
        ${sso.adminGroup} = oidcScopes ++ [ "home_groups" ];
        ${sso.userGroup} = oidcScopes ++ [ "home_groups" ];
      };
      claimMaps.home_groups.valuesByGroup = {
        ${sso.adminGroup} = [ sso.adminGroup ];
        ${sso.userGroup} = [ sso.userGroup ];
      };
    };

    services.home-assistant = {
      customComponents = [ pkgs.home-assistant-custom-components.auth_oidc ];
      config.auth_oidc = {
        client_id = oidcClient.clientId;
        discovery_url = oidcClient.discoveryUrl;
        display_name = "SSO";
        id_token_signing_alg = "ES256";
        groups_scope = "home_groups";
        additional_scopes = [ "email" ];
        claims = {
          display_name = "name";
          username = "preferred_username";
          groups = "home_groups";
        };
        roles = {
          admin = sso.adminGroup;
          user = sso.userGroup;
        };
        features = {
          automatic_user_linking = true;
          automatic_person_creation = true;
          default_redirect = true;
          force_https = true;
        };
      };
    };
  };
}
