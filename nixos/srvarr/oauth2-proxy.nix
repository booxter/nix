{ hostInventory, lib, ... }:
let
  clientId = "srvarr-admin-apps";
  oauth2ProxyCookieName = "_srvarr_admin_sso";
  protectedServiceIds = hostInventory.srvarrAdminAppIds;
  protectedServiceHosts = lib.unique (
    lib.concatMap hostInventory.toInternalHttpsServiceHosts protectedServiceIds
  );
  # Bazarr has no reverse-proxy auth mode here: its config has `auth.type: null`,
  # but the UI still calls `POST /api/system/account` on logout. Bazarr returns
  # 500 for that state because its logout endpoint only accepts `form` or
  # `basic` auth. Handle that logout at nginx instead so the request succeeds
  # and, more importantly, clears the oauth2-proxy session cookies that actually
  # control browser SSO access for this vhost.
  bazarrLogoutLocations = {
    "= /api/system/account" = {
      return = "204";
      extraConfig = ''
        auth_request off;
        add_header Set-Cookie "${oauth2ProxyCookieName}=; Path=/; Max-Age=0; HttpOnly; Secure" always;
        add_header Set-Cookie "${oauth2ProxyCookieName}_0=; Path=/; Max-Age=0; HttpOnly; Secure" always;
        add_header Set-Cookie "${oauth2ProxyCookieName}_1=; Path=/; Max-Age=0; HttpOnly; Secure" always;
        add_header Set-Cookie "${oauth2ProxyCookieName}_2=; Path=/; Max-Age=0; HttpOnly; Secure" always;
        add_header Set-Cookie "${oauth2ProxyCookieName}_csrf=; Path=/; Max-Age=0; HttpOnly; Secure" always;
      '';
    };
  };
in
{
  host.sso.oauth2ProxyGates.srvarr-admin-apps = {
    enable = true;
    inherit clientId;
    cookieName = oauth2ProxyCookieName;
    secretOwner = "oauth2-proxy";
    secretGroup = "oauth2-proxy";
    allowedGroups = [ "infra-admins" ];
    groupClaim = "infra_groups";
    whitelistDomains = protectedServiceHosts;
    internalHttpsServiceNames = protectedServiceIds;
    signInLocationName = "@oauth2_proxy_sign_in";
    authCookieVariableName = "auth_cookie";
    clearAuthorizationHeader = false;
    authRequestHeaders = [
      {
        variableName = "user";
        upstreamHeader = "x_auth_request_user";
        proxyHeader = "X-User";
      }
      {
        variableName = "email";
        upstreamHeader = "x_auth_request_email";
        proxyHeader = "X-Email";
      }
    ];
    extraLocationsByName.bazarr = bazarrLogoutLocations;
  };
}
