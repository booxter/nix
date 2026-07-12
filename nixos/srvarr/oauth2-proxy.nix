{
  config,
  hostInventory,
  lib,
  ...
}:
let
  clientId = "srvarr-admin-apps";
  oauth2ProxyCookieName = "_srvarr_admin_sso";
  protectedServiceIds = hostInventory.srvarrAdminAppIds;
  protectedServiceHosts = lib.unique (
    lib.concatMap hostInventory.toInternalHttpsServiceHosts protectedServiceIds
  );
  backendPorts = {
    bazarr = config.services.bazarr.listenPort;
    houndarr = config.systemd.services.houndarr.environment.HOUNDARR_PORT;
    lidarr = config.services.lidarr.settings.server.port;
    prowlarr = config.services.prowlarr.settings.server.port;
    radarr = config.services.radarr.settings.server.port;
    sabnzbd = config.services.sabnzbd.settings.misc.port;
    sonarr = config.services.sonarr.settings.server.port;
    transmission = config.services.transmission.settings.rpc-port;
  };
  localBackendProxyHeaders = ''
    proxy_set_header Host ${config.networking.hostName};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
  mkBackendProbeLocation =
    {
      port,
      upstreamPath ? null,
      recommendedProxySettings ? true,
      extraConfig ? "",
    }:
    {
      proxyPass = "http://127.0.0.1:${toString port}${
        lib.optionalString (upstreamPath != null) upstreamPath
      }";
      inherit recommendedProxySettings;
      extraConfig = ''
        auth_request off;
      ''
      + extraConfig;
    };
  mkBackendProbePathLocation = serviceName: path: {
    ${path} = mkBackendProbeLocation {
      port = backendPorts.${serviceName};
    };
  };
  servarrPingProbeLocations = lib.genAttrs [
    "lidarr"
    "prowlarr"
    "radarr"
    "sonarr"
  ] (serviceName: mkBackendProbePathLocation serviceName "= /ping");
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
  backendProbeLocationsByName = servarrPingProbeLocations // {
    bazarr = mkBackendProbePathLocation "bazarr" "= /api/system/ping";
    houndarr = mkBackendProbePathLocation "houndarr" "= /api/health";
    sabnzbd."= /__probe/sabnzbd-version" = mkBackendProbeLocation {
      port = backendPorts.sabnzbd;
      upstreamPath = "/api?mode=version&output=json";
      recommendedProxySettings = false;
      # SABnzbd rejects arbitrary Host headers even for the version API. Use
      # the local machine name accepted by its hostname check while still
      # exposing only this exact unauthenticated probe URL.
      extraConfig = localBackendProxyHeaders;
    };
    transmission."= /__probe/transmission-rpc" = mkBackendProbeLocation {
      port = backendPorts.transmission;
      upstreamPath = "/transmission/rpc";
      recommendedProxySettings = false;
      # Transmission's RPC host whitelist expects the upstream hop to use the
      # local host name; this probe alias is method-limited so the auth bypass
      # can observe the RPC endpoint's CSRF 409 without exposing RPC actions.
      extraConfig = ''
        limit_except GET {
          deny all;
        }
      ''
      + localBackendProxyHeaders;
    };
  };
in
{
  host.sso.oauth2ProxyGates.srvarr-admin-apps = {
    enable = true;
    inherit clientId;
    cookieName = oauth2ProxyCookieName;
    allowedGroups = [ "media-admins" ];
    groupClaim = "media_groups";
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
    probeLocationsByName = backendProbeLocationsByName;
  };
}
