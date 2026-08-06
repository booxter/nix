{
  config,
  hostInventory,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  issuerBaseUrl = "https://${hostInventory.servicesById.id.publicHost}";
  baseScopes = [
    "openid"
    "email"
    "profile"
  ];
  registrationType = types.submodule (
    { name, ... }:
    {
      options = {
        clientId = mkOption {
          type = types.str;
          default = name;
          description = "OIDC client identifier registered with Kanidm.";
        };

        displayName = mkOption {
          type = types.str;
          description = "Display name shown by the identity provider.";
        };

        originUrls = mkOption {
          type = types.listOf types.str;
          description = "Allowed redirect origins for the OIDC client.";
        };

        originLanding = mkOption {
          type = types.str;
          description = "Landing page for the OIDC client.";
        };

        public = mkOption {
          type = types.bool;
          default = false;
          description = "Whether the client authenticates without a client secret.";
        };

        allowInsecureClientDisablePkce = mkOption {
          type = types.bool;
          default = false;
          description = "Whether Kanidm may disable PKCE for this client.";
        };

        enableLocalhostRedirects = mkOption {
          type = types.bool;
          default = false;
          description = "Whether Kanidm permits localhost redirects.";
        };

        enableLegacyCrypto = mkOption {
          type = types.bool;
          default = false;
          description = "Whether Kanidm permits legacy cryptography.";
        };

        preferShortUsername = mkOption {
          type = types.bool;
          default = true;
          description = "Whether Kanidm should emit short preferred usernames.";
        };

        scopeMaps = mkOption {
          type = types.attrsOf (types.listOf types.str);
          default = { };
          description = "Scopes granted to members of each Kanidm group.";
        };

        claimMaps = mkOption {
          type = types.attrsOf (
            types.submodule {
              options.valuesByGroup = mkOption {
                type = types.attrsOf (types.listOf types.str);
                default = { };
                description = "Claim values emitted for members of each Kanidm group.";
              };
            }
          );
          default = { };
          description = "Additional OIDC claims derived from Kanidm groups.";
        };

        secret = mkOption {
          type = types.submodule {
            options = {
              sopsKey = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "SOPS key containing the local copy of the client secret.";
              };

              name = mkOption {
                type = types.str;
                default = "oidc-${name}-client-secret";
                description = "Local sops-nix secret name.";
              };

              owner = mkOption {
                type = types.str;
                default = "root";
                description = "Owner of the materialized client secret.";
              };

              group = mkOption {
                type = types.str;
                default = "root";
                description = "Group of the materialized client secret.";
              };

              mode = mkOption {
                type = types.str;
                default = "0400";
                description = "Mode of the materialized client secret.";
              };

              restartUnits = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Units restarted when the client secret changes.";
              };
            };
          };
          default = { };
          description = "Local materialization of a confidential client secret.";
        };
      };
    }
  );
  registrations = config.host.sso.oidc.registrations;
  clients = lib.mapAttrs (
    _: registration:
    let
      openidBaseUrl = "${issuerBaseUrl}/oauth2/openid/${registration.clientId}";
      secret = registration.secret;
    in
    registration
    // {
      inherit
        baseScopes
        issuerBaseUrl
        ;
      authorizationUrl = "${issuerBaseUrl}/ui/oauth2";
      discoveryUrl = "${openidBaseUrl}/.well-known/openid-configuration";
      issuerUrl = openidBaseUrl;
      jwksUrl = "${openidBaseUrl}/public_key.jwk";
      tokenUrl = "${issuerBaseUrl}/oauth2/token";
      userinfoUrl = "${openidBaseUrl}/userinfo";
      secret = secret // {
        path = if registration.public then null else config.sops.secrets.${secret.name}.path;
        placeholder = if registration.public then null else config.sops.placeholder.${secret.name};
      };
    }
  ) registrations;
  confidentialRegistrations = lib.filterAttrs (_: registration: !registration.public) registrations;
in
{
  options.host.sso.oidc = {
    baseScopes = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      internal = true;
      description = "Standard scopes requested by every OIDC client.";
    };

    registrations = mkOption {
      type = types.attrsOf registrationType;
      default = { };
      description = "OIDC clients required by services on this host.";
    };

    clients = mkOption {
      type = types.attrsOf types.anything;
      readOnly = true;
      internal = true;
      description = "OIDC registrations enriched with provider endpoints and local secrets.";
    };
  };

  config = {
    assertions = lib.concatMap (registration: [
      {
        assertion = registration.originUrls != [ ];
        message = "OIDC client ${registration.clientId} must declare at least one origin URL.";
      }
      {
        assertion = registration.public == (registration.secret.sopsKey == null);
        message = "OIDC client ${registration.clientId} must declare a secret exactly when confidential.";
      }
    ]) (builtins.attrValues registrations);

    host.sso.oidc = {
      inherit baseScopes;
      clients = clients;
    };

    sops.secrets = lib.mapAttrs' (
      _: registration:
      lib.nameValuePair registration.secret.name {
        key = registration.secret.sopsKey;
        inherit (registration.secret)
          group
          mode
          owner
          restartUnits
          ;
      }
    ) confidentialRegistrations;
  };
}
