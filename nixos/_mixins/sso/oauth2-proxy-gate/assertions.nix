{
  config,
  lib,
  webModel,
  ...
}:
let
  gates = config.host.sso.oauth2ProxyGates;
  ports = map (gate: gate.port) (builtins.attrValues gates);
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
            assertion = gate.internalHttpsServiceNames != [ ] && unknownInternalEndpoints == [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.internalHttpsServiceNames contains unknown internal web endpoints: ${lib.concatStringsSep ", " unknownInternalEndpoints}";
          }
        ]
        ++ lib.optional (gate.sessionRefresh != null) {
          assertion = gate.sessionRefresh.intervalSeconds < gate.sessionRefresh.lifetimeSeconds;
          message = "host.sso.oauth2ProxyGates.${gateName}.sessionRefresh.intervalSeconds must be less than lifetimeSeconds.";
        }
      ) gates
    )
    ++ [
      {
        assertion = builtins.length ports == builtins.length (lib.unique ports);
        message = "host.sso.oauth2ProxyGates must use unique ports.";
      }
    ];
}
