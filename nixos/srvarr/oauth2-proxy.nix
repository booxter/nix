{
  config,
  hostInventory,
  lib,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  clientId = "srvarr-admin-apps";
  issuerUrl = "https://${idService.publicHost}/oauth2/openid/${clientId}";
  oauth2ProxyUrl = config.services.oauth2-proxy.httpAddress;
  protectedServiceIds = hostInventory.srvarrAdminAppIds;
  protectedServiceHosts = lib.unique (
    lib.concatMap hostInventory.toInternalHttpsServiceHosts protectedServiceIds
  );
  authRequestLocationConfig = ''
    auth_request /oauth2/auth;
    error_page 401 = @oauth2_proxy_sign_in;

    auth_request_set $user $upstream_http_x_auth_request_user;
    auth_request_set $email $upstream_http_x_auth_request_email;
    auth_request_set $auth_cookie $upstream_http_set_cookie;

    proxy_set_header X-User $user;
    proxy_set_header X-Email $email;
    add_header Set-Cookie $auth_cookie;
  '';
  oauth2ProxyLocations = {
    "/oauth2/" = {
      proxyPass = oauth2ProxyUrl;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Auth-Request-Redirect $scheme://$host$request_uri;
      '';
    };

    "= /oauth2/auth" = {
      proxyPass = "${oauth2ProxyUrl}/oauth2/auth";
      recommendedProxySettings = true;
      extraConfig = ''
        internal;
        auth_request off;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
      '';
    };

    "@oauth2_proxy_sign_in" = {
      return = "307 $scheme://$host/oauth2/start?rd=$scheme://$host$request_uri";
      extraConfig = ''
        auth_request off;
      '';
    };
  };
in
{
  sops.secrets = {
    oauth2ProxySrvarrAdminAppsClientSecret = {
      key = "oauth2-proxy/srvarr-admin-apps/client_secret";
      owner = "oauth2-proxy";
      group = "oauth2-proxy";
      mode = "0400";
      restartUnits = [ "oauth2-proxy.service" ];
    };
    oauth2ProxySrvarrAdminAppsCookieSecret = {
      key = "oauth2-proxy/srvarr-admin-apps/cookie_secret";
      owner = "oauth2-proxy";
      group = "oauth2-proxy";
      mode = "0400";
      restartUnits = [ "oauth2-proxy.service" ];
    };
  };

  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = issuerUrl;
    clientID = clientId;
    clientSecretFile = config.sops.secrets.oauth2ProxySrvarrAdminAppsClientSecret.path;
    approvalPrompt = "auto";
    cookie = {
      name = "_srvarr_admin_sso";
      secretFile = config.sops.secrets.oauth2ProxySrvarrAdminAppsCookieSecret.path;
    };
    email.domains = [ "*" ];
    scope = "openid email profile infra_groups";
    upstream = [ "static://202" ];
    reverseProxy = true;
    trustedProxyIP = [
      "127.0.0.1/32"
      "::1/128"
    ];
    setXauthrequest = true;
    passBasicAuth = false;
    extraConfig = {
      allowed-group = [ "infra-admins" ];
      code-challenge-method = "S256";
      oidc-groups-claim = "infra_groups";
      skip-provider-button = true;
      whitelist-domain = protectedServiceHosts;
    };
  };

  host.internalHttps.services = lib.genAttrs protectedServiceIds (_: {
    locationExtraConfig = authRequestLocationConfig;
  });

  services.nginx.virtualHosts = builtins.listToAttrs (
    map (serviceName: {
      name = "internal-https-${serviceName}";
      value.locations = oauth2ProxyLocations;
    }) protectedServiceIds
  );

  systemd.services.oauth2-proxy = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
}
