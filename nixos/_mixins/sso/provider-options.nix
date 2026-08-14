{ config, lib, ... }:
{
  options.host.sso = {
    providerHost = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      internal = true;
      description = "Host providing SSO for this host's realm.";
    };

    provider.enable = lib.mkEnableOption "this host as its realm's SSO provider";
  };

  config.assertions = [
    {
      assertion =
        !config.host.sso.provider.enable || config.networking.hostName == config.host.sso.providerHost;
      message = "The enabled SSO provider must match host.sso.providerHost.";
    }
    {
      assertion = config.host.sso.oidc.registrations == { } || config.host.sso.providerHost != null;
      message = "OIDC registrations require an SSO provider for realm '${config.host.realm}'.";
    }
  ];
}
