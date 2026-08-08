{
  config,
  hostInventory,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.sso.provider;
  sso = hostInventory.sso;
  clients = import ./provider-clients.nix {
    inherit lib outputs;
    providerHost = cfg.host;
    realm = config.host.realm;
  };
  secretName = clientId: "kanidm-oauth2-${clientId}-client-secret";
  secretKey = clientId: "kanidm/oauth2/${clientId}/client_secret";
  confidentialClients = lib.filterAttrs (_: client: !client.public) clients;
  referencedGroups = lib.unique (
    lib.concatMap (
      client:
      builtins.attrNames client.scopeMaps
      ++ lib.concatMap (claimMap: builtins.attrNames claimMap.valuesByGroup) (
        builtins.attrValues client.claimMaps
      )
    ) (builtins.attrValues clients)
  );
  unknownGroups = lib.subtractLists (builtins.attrNames sso.groups) referencedGroups;
  provisionClients =
    secretPathFor:
    lib.mapAttrs (_: client: {
      inherit (client)
        allowInsecureClientDisablePkce
        claimMaps
        displayName
        enableLocalhostRedirects
        enableLegacyCrypto
        originLanding
        preferShortUsername
        public
        scopeMaps
        ;
      originUrl =
        if builtins.length client.originUrls == 1 then
          builtins.head client.originUrls
        else
          client.originUrls;
      basicSecretFile = if client.public then null else secretPathFor client.clientId;
    }) clients;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unknownGroups == [ ];
        message = "OIDC registrations reference unknown Kanidm groups: ${lib.concatStringsSep ", " unknownGroups}";
      }
    ];

    sops.secrets = lib.mapAttrs' (
      _: client:
      lib.nameValuePair (secretName client.clientId) {
        key = secretKey client.clientId;
        owner = "kanidm";
        group = "kanidm";
        mode = "0400";
        restartUnits = [ "kanidm.service" ];
      }
    ) confidentialClients;

    services.kanidm.provision.systems.oauth2 = provisionClients (
      clientId: config.sops.secrets.${secretName clientId}.path
    );
  };
}
