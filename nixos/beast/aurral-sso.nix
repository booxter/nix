{
  config,
  hostInventory,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  aurralService = hostInventory.servicesById.aurral;
  clientId = "aurral";
  issuerUrl = "https://${idService.publicHost}/oauth2/openid/${clientId}";
  oauth2ProxyCookieName = "_aurral_sso";
  oauth2ProxyUrl = config.services.oauth2-proxy.httpAddress;
  authRequestLocationConfig = ''
    auth_request /oauth2/auth;
    error_page 401 = @aurral_oauth2_proxy_sign_in;

    auth_request_set $aurral_user $upstream_http_x_auth_request_preferred_username;
    auth_request_set $aurral_email $upstream_http_x_auth_request_email;
    auth_request_set $aurral_groups $upstream_http_x_auth_request_groups;
    auth_request_set $aurral_auth_cookie $upstream_http_set_cookie;

    proxy_set_header X-Forwarded-User $aurral_user;
    proxy_set_header X-Forwarded-Email $aurral_email;
    proxy_set_header X-Forwarded-Groups $aurral_groups;
    proxy_set_header Authorization "";
    add_header Set-Cookie $aurral_auth_cookie;
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

    "@aurral_oauth2_proxy_sign_in" = {
      return = "307 $scheme://$host/oauth2/start?rd=$scheme://$host$request_uri";
      extraConfig = ''
        auth_request off;
      '';
    };
  };
in
{
  sops.secrets = {
    oauth2ProxyAurralClientSecret = {
      key = "oauth2-proxy/aurral/client_secret";
      owner = "oauth2-proxy";
      group = "oauth2-proxy";
      mode = "0400";
      restartUnits = [ "oauth2-proxy.service" ];
    };
    oauth2ProxyAurralCookieSecret = {
      key = "oauth2-proxy/aurral/cookie_secret";
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
    clientSecretFile = config.sops.secrets.oauth2ProxyAurralClientSecret.path;
    approvalPrompt = "auto";
    cookie = {
      name = oauth2ProxyCookieName;
      secretFile = config.sops.secrets.oauth2ProxyAurralCookieSecret.path;
    };
    email.domains = [ "*" ];
    scope = "openid email profile media_groups";
    upstream = [ "static://202" ];
    reverseProxy = true;
    trustedProxyIP = [
      "127.0.0.1/32"
      "::1/128"
    ];
    setXauthrequest = true;
    passBasicAuth = false;
    extraConfig = {
      allowed-group = [
        "media-admins"
        "media-users"
      ];
      code-challenge-method = "S256";
      oidc-groups-claim = "media_groups";
      skip-provider-button = true;
      whitelist-domain = [ aurralService.publicHost ];
    };
  };

  host.externalService.virtualHosts.${aurralService.publicHost}.locationExtraConfig =
    authRequestLocationConfig;

  services.nginx.virtualHosts.${aurralService.publicHost}.locations = oauth2ProxyLocations;

  systemd.services.oauth2-proxy = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
}
