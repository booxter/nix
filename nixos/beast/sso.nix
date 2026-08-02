{ hostInventory, ... }:
let
  aurralService = hostInventory.servicesById.aurral;
  redisPort = 6379;
  redisServiceUnit = "redis-oauth2-proxy-aurral.service";
in
{
  services.redis.servers.oauth2-proxy-aurral = {
    enable = true;
    bind = "127.0.0.1";
    port = redisPort;
    openFirewall = false;
    save = [ ];
    appendOnly = false;
    settings = {
      maxmemory = "64mb";
      maxmemory-policy = "volatile-ttl";
    };
  };

  host.sso.oauth2ProxyGates.aurral = {
    enable = true;
    clientId = "aurral";
    cookieName = "_aurral_sso";
    allowedGroups = [
      "media-admins"
      "media-users"
    ];
    groupClaim = "media_groups";
    # Kanidm access tokens live for 15 minutes, so refresh one minute early.
    # Keep the Redis ticket aligned with Kanidm's eight-hour login session.
    sessionRefresh = {
      intervalSeconds = 14 * 60;
      lifetimeSeconds = 8 * 60 * 60;
      redisConnectionUrl = "redis://127.0.0.1:${toString redisPort}/0";
      inherit redisServiceUnit;
    };
    whitelistDomains = [ aurralService.publicHost ];
    externalHostNames = [ aurralService.publicHost ];
    signInLocationName = "@aurral_oauth2_proxy_sign_in";
    authCookieVariableName = "aurral_auth_cookie";
    authRequestHeaders = [
      {
        variableName = "aurral_user";
        upstreamHeader = "x_auth_request_preferred_username";
        proxyHeader = "X-Forwarded-User";
      }
      {
        variableName = "aurral_email";
        upstreamHeader = "x_auth_request_email";
        proxyHeader = "X-Forwarded-Email";
      }
      {
        variableName = "aurral_groups";
        upstreamHeader = "x_auth_request_groups";
        proxyHeader = "X-Forwarded-Groups";
      }
    ];
  };
}
