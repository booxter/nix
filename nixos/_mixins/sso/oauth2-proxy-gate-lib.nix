{ }:
{
  redisServerName = gateName: "oauth2-proxy-${gateName}";

  redisServiceUnit = gateName: "redis-oauth2-proxy-${gateName}.service";

  redisConnectionUrl = gate: "redis://127.0.0.1:${toString gate.sessionRefresh.redisPort}/0";
}
