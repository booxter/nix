{
  config,
  lib,
  webModel,
  ...
}:
let
  enabledGates = lib.filterAttrs (_: gate: gate.enable) config.host.sso.oauth2ProxyGates;
  serviceNames = map (gate: gate.serviceName) (builtins.attrValues enabledGates);
  httpAddresses = map (gate: gate.httpAddress) (builtins.attrValues enabledGates);
in
{
  assertions =
    builtins.concatLists (
      lib.mapAttrsToList (
        gateName: gate:
        let
          unknownInternalEndpoints = builtins.filter (
            endpointName: !(builtins.hasAttr endpointName webModel.internalEndpoints)
          ) gate.internalHttpsServiceNames;
        in
        [
          {
            assertion = gate.allowedGroups != [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.allowedGroups must not be empty.";
          }
          {
            assertion = gate.whitelistDomains != [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.whitelistDomains must not be empty.";
          }
          {
            assertion = unknownInternalEndpoints == [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.internalHttpsServiceNames contains unknown internal web endpoints: ${lib.concatStringsSep ", " unknownInternalEndpoints}";
          }
        ]
        ++ lib.optional (gate.sessionRefresh != null) {
          assertion = gate.sessionRefresh.intervalSeconds < gate.sessionRefresh.lifetimeSeconds;
          message = "host.sso.oauth2ProxyGates.${gateName}.sessionRefresh.intervalSeconds must be less than lifetimeSeconds.";
        }
      ) enabledGates
    )
    ++ [
      {
        assertion = builtins.length serviceNames == builtins.length (lib.unique serviceNames);
        message = "host.sso.oauth2ProxyGates must use unique serviceName values.";
      }
      {
        assertion = builtins.length httpAddresses == builtins.length (lib.unique httpAddresses);
        message = "host.sso.oauth2ProxyGates must use unique httpAddress values.";
      }
    ];
}
