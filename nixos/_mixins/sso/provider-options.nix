{ config, lib, ... }:
{
  options.host.sso = {
    providerHost = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      internal = true;
      description = "Host providing SSO for this host's realm.";
    };

    provider = lib.mkOption {
      type = with lib.types; nullOr (submodule { });
      default = null;
      description = "This host's role as its realm's SSO provider.";
    };
  };

  config.assertions = [
    {
      assertion =
        config.host.sso.provider == null || config.networking.hostName == config.host.sso.providerHost;
      message = "The SSO provider must match host.sso.providerHost.";
    }
    {
      assertion = config.host.sso.oidc.registrations == { } || config.host.sso.providerHost != null;
      message = "OIDC registrations require an SSO provider for realm '${config.host.realm}'.";
    }
  ];
}
