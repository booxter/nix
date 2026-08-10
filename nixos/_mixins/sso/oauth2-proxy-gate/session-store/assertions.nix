{
  config,
  lib,
  ...
}:
let
  enabledRedisServers = lib.filterAttrs (_: server: server.enable) config.services.redis.servers;
  redisPorts = map (server: server.port) (builtins.attrValues enabledRedisServers);
in
{
  config.assertions = [
    {
      assertion = builtins.length redisPorts == builtins.length (lib.unique redisPorts);
      message = "enabled Redis servers must use unique ports";
    }
  ];
}
