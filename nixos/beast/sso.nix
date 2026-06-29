{ hostInventory, ... }:
let
  aurralService = hostInventory.servicesById.aurral;
in
{
  host.sso.oauth2ProxyGates.aurral = {
    enable = true;
    clientId = "aurral";
    cookieName = "_aurral_sso";
    allowedGroups = [
      "media-admins"
      "media-users"
    ];
    groupClaim = "media_groups";
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
