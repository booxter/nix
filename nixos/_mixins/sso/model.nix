{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  localProvider = {
    hostName = localHost;
    inherit (config.host) realm;
    inherit (config.host.sso) role provider;
  };
  otherConfigurations = builtins.removeAttrs outputs.nixosConfigurations [ localHost ];
  otherProviders = lib.mapAttrs (_: configuration: {
    hostName = configuration.config.networking.hostName;
    inherit (configuration.config.host) realm;
    inherit (configuration.config.host.sso) role provider;
  }) otherConfigurations;
  candidates = otherProviders // {
    ${localHost} = localProvider;
  };
  realmProviders = lib.filterAttrs (
    _: candidate: candidate.realm == config.host.realm && candidate.role == "provider"
  ) candidates;
  providerNames = builtins.attrNames realmProviders;
  realmProvider =
    if builtins.length providerNames == 1 then
      let
        candidate = realmProviders.${builtins.head providerNames};
      in
      {
        inherit (candidate) hostName realm;
        inherit (candidate.provider)
          backend
          displayName
          publicUrl
          ;
        inherit (candidate.provider.oidc) baseScopes;
      }
    else
      null;
in
{
  inherit providerNames realmProvider;
}
