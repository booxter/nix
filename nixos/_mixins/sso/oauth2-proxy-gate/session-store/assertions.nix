{
  config,
  lib,
  ...
}:
let
  enabledGates = lib.filterAttrs (
    _: gate: gate.enable && gate.sessionRefresh != null
  ) config.host.sso.oauth2ProxyGates;
  redisPorts = map (gate: gate.sessionRefresh.redisPort) (builtins.attrValues enabledGates);
in
{
  config.assertions = [
    {
      assertion = builtins.length redisPorts == builtins.length (lib.unique redisPorts);
      message = "oauth2-proxy Redis session stores must use unique ports";
    }
  ];
}
