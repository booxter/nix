{
  lib,
  localRegistrations,
  outputs,
  providerHost,
  realm,
}:
let
  consumerConfigurations = lib.filterAttrs (_: host: host.config.host.realm == realm) (
    removeAttrs outputs.nixosConfigurations [ providerHost ]
  );
  localContributions = lib.mapAttrsToList (registrationName: registration: {
    hostName = providerHost;
    inherit registrationName;
    provider = removeAttrs registration [ "secret" ];
  }) localRegistrations;
  remoteContributions = lib.concatLists (
    lib.mapAttrsToList (
      hostName: host:
      lib.mapAttrsToList (registrationName: registration: {
        inherit
          hostName
          registrationName
          ;
        provider = removeAttrs registration [ "secret" ];
      }) host.config.host.sso.oidc.registrations
    ) consumerConfigurations
  );
  contributions = localContributions ++ remoteContributions;
  contributionsByClientId = builtins.groupBy (
    contribution: contribution.provider.clientId
  ) contributions;
  clientFor =
    clientId: clientContributions:
    let
      providers = lib.unique (map (contribution: contribution.provider) clientContributions);
      sources = map (
        contribution: "${contribution.hostName}:${contribution.registrationName}"
      ) clientContributions;
    in
    if builtins.length providers == 1 then
      builtins.head providers
    else
      throw "OIDC client ${clientId} has conflicting registrations from ${lib.concatStringsSep ", " sources}";
in
lib.mapAttrs clientFor contributionsByClientId
