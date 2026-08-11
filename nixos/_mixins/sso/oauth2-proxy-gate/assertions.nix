{ config, lib, ... }:
let
  enabledGates = lib.filterAttrs (_: gate: gate.enable) config.host.sso.oauth2ProxyGates;
  probeHelpers = import ../oauth2-proxy-gate-probes.nix { inherit lib; };
  serviceNames = map (gate: gate.serviceName) (builtins.attrValues enabledGates);
  httpAddresses = map (gate: gate.httpAddress) (builtins.attrValues enabledGates);
in
{
  assertions =
    builtins.concatLists (
      lib.mapAttrsToList (
        gateName: gate:
        [
          {
            assertion = gate.allowedGroups != [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.allowedGroups must not be empty.";
          }
          {
            assertion = gate.whitelistDomains != [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.whitelistDomains must not be empty.";
          }
        ]
        ++ lib.optional (gate.sessionRefresh != null) {
          assertion = gate.sessionRefresh.intervalSeconds < gate.sessionRefresh.lifetimeSeconds;
          message = "host.sso.oauth2ProxyGates.${gateName}.sessionRefresh.intervalSeconds must be less than lifetimeSeconds.";
        }
        ++ probeHelpers.assertionsFor gateName gate
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
