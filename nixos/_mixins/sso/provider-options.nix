{
  config,
  hostSpec,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      hostSpec
      lib
      outputs
      ;
  };
  realmProviderType = lib.types.submodule {
    options = {
      hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Host providing SSO for the realm.";
      };
      realm = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Realm served by this SSO provider.";
      };
      backend = lib.mkOption {
        type = lib.types.enum [ "kanidm" ];
        description = "Identity provider implementation.";
      };
      displayName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Human-readable identity provider name.";
      };
      publicUrl = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Public base URL of the identity provider.";
      };
      baseScopes = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        description = "OIDC scopes requested by every client.";
      };
    };
  };
in
{
  options.host.sso = {
    role = lib.mkOption {
      type = with lib.types; nullOr (enum [ "provider" ]);
      default = null;
      description = "Realm SSO role claimed by this host.";
    };

    provider = {
      backend = lib.mkOption {
        type = lib.types.enum [ "kanidm" ];
        default = "kanidm";
        description = "Identity provider implementation activated by the provider role.";
      };
      displayName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "SSO";
        description = "Human-readable identity provider name.";
      };
      publicUrl = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "https://id.${config.host.network.publicDomain}";
        description = "Public base URL of the identity provider.";
      };
      oidc.baseScopes = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [
          "openid"
          "email"
          "profile"
        ];
        description = "OIDC scopes requested by every client.";
      };
      mail.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the provider sends enrollment and credential-reset mail.";
      };
    };

    realmProvider = lib.mkOption {
      type = with lib.types; nullOr realmProviderType;
      default = model.realmProvider;
      readOnly = true;
      internal = true;
      description = "SSO provider discovered for this host's realm.";
    };
  };

  config.assertions = [
    {
      assertion = builtins.length model.providerNames <= 1;
      message = "Realm '${config.host.realm}' has multiple SSO providers: ${lib.concatStringsSep ", " model.providerNames}";
    }
    {
      assertion = config.host.sso.oidc.registrations == { } || model.realmProvider != null;
      message = "OIDC registrations require an SSO provider in realm '${config.host.realm}'.";
    }
  ];
}
