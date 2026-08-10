{ config, ... }:
let
  aurralPublicHost = "mu.${config.host.network.publicDomain}";
  aurralPublicUrl = "https://${aurralPublicHost}";
in
{
  host.sso.oauth2ProxyGates.aurral = {
    enable = true;
    clientId = "aurral";
    displayName = "Aurral";
    originLanding = "${aurralPublicUrl}/";
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
    };
    whitelistDomains = [ aurralPublicHost ];
    externalHostNames = [ aurralPublicHost ];
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
