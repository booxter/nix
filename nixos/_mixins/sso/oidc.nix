{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  providerHost = config.host.sso.providerHost;
  issuerBaseUrl =
    if providerHost == null then null else "https://id.${config.host.network.publicDomain}";
  baseScopes = lib.optionals (providerHost != null) [
    "openid"
    "email"
    "profile"
  ];
  registrationType = types.submodule (
    { name, ... }:
    {
      options = {
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

        allowInsecureClientDisablePkce = mkOption {
          type = types.bool;
          default = false;
          description = "Whether Kanidm may disable PKCE for this client.";
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
          type = types.nullOr (
            types.submodule {
              options = {
                sopsKey = mkOption {
                  type = types.str;
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
            }
          );
          default = null;
          description = "Local materialization of a confidential client secret.";
        };
      };
    }
  );
  registrations = config.host.sso.oidc.registrations;
  clients = lib.mapAttrs (
    clientId: registration:
    let
      providerUrl =
        assert issuerBaseUrl != null;
        issuerBaseUrl;
      openidBaseUrl = "${providerUrl}/oauth2/openid/${clientId}";
      secret = registration.secret;
    in
    registration
    // {
      inherit baseScopes clientId;
      public = secret == null;
      issuerBaseUrl = providerUrl;
      authorizationUrl = "${providerUrl}/ui/oauth2";
      discoveryUrl = "${openidBaseUrl}/.well-known/openid-configuration";
      issuerUrl = openidBaseUrl;
      jwksUrl = "${openidBaseUrl}/public_key.jwk";
      tokenUrl = "${providerUrl}/oauth2/token";
      userinfoUrl = "${openidBaseUrl}/userinfo";
      secret =
        if secret == null then
          null
        else
          secret
          // {
            path = config.sops.secrets.${secret.name}.path;
            placeholder = config.sops.placeholder.${secret.name};
          };
    }
  ) registrations;
  confidentialRegistrations = lib.filterAttrs (
    _: registration: registration.secret != null
  ) registrations;
in
{
  imports = [ ./oidc/assertions.nix ];

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
