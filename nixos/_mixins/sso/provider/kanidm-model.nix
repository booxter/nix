{
  config,
  lib,
  outputs,
}:
let
  sso = config.host.sso;
  oidcClients = import ./oidc-clients.nix {
    inherit lib outputs;
    inherit (config.host) realm;
    localRegistrations = sso.oidc.registrations;
    providerHost = config.networking.hostName;
  };
  referencedOidcGroups = lib.unique (
    lib.concatMap (
      client:
      builtins.attrNames client.scopeMaps
      ++ lib.concatMap (claimMap: builtins.attrNames claimMap.valuesByGroup) (
        builtins.attrValues client.claimMaps
      )
    ) (builtins.attrValues oidcClients)
  );
in
rec {
  enabled = sso.provider != null;
  idPublicHost = "id.${config.host.network.publicDomain}";
  publicUrl = "https://${idPublicHost}";
  kanidmPort = 18085;
  kanidmLocalHost = "id";
  kanidmLocalUrl = "https://${kanidmLocalHost}:${toString kanidmPort}";
  kanidmOAuthSecretAttrName = clientId: "kanidm-oauth2-${clientId}-client-secret";
  kanidmOAuthSecretKey = clientId: "kanidm/oauth2/${clientId}/client_secret";
  confidentialOidcClients = lib.filterAttrs (_: client: !client.public) oidcClients;
  unknownOidcGroups = lib.subtractLists sso.groups referencedOidcGroups;
  kanidmProvisionGroups = lib.genAttrs sso.groups (_: { });
  kanidmProvisionPersons = lib.mapAttrs (name: person: {
    displayName = name;
    groups = person.groups;
  }) sso.users;
  kanidmProvisionClients =
    secretPathFor:
    lib.mapAttrs (_: client: {
      inherit (client)
        allowInsecureClientDisablePkce
        claimMaps
        displayName
        originLanding
        public
        scopeMaps
        ;
      preferShortUsername = true;
      originUrl =
        if builtins.length client.originUrls == 1 then
          builtins.head client.originUrls
        else
          client.originUrls;
      basicSecretFile = if client.public then null else secretPathFor client.clientId;
    }) oidcClients;
}
