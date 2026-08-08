{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  gates = lib.filterAttrs (_: gate: gate.ownerHost == hostname) hostInventory.sso.oauth2ProxyGates;
  gateConfig =
    gate:
    let
      originHost = lib.head (hostInventory.toInternalServiceHosts gate.originLandingServiceId);
    in
    {
      enable = true;
      clientId = gate.id;
      inherit (gate)
        clearAuthorizationHeader
        cookieName
        displayName
        groupClaim
        ;
      originLanding = "https://${originHost}/";
      inherit (gate) allowedGroups;
      whitelistDomains = lib.unique (lib.concatMap hostInventory.toInternalServiceHosts gate.serviceIds);
      internalServiceNames = gate.serviceIds;
    };
in
{
  config.host.sso.oauth2ProxyGates = lib.mapAttrs' (
    _: gate: lib.nameValuePair gate.id (gateConfig gate)
  ) gates;
}
