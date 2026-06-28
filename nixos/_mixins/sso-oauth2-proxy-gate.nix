{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.sso.oauth2ProxyGate;
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  safeClientId = lib.replaceStrings [ "-" ] [ "_" ] cfg.clientId;
  issuerUrl = oidc.openidBaseUrl cfg.clientId;
  oauth2ProxyUrl = config.services.oauth2-proxy.httpAddress;
  authCookieVariable = "$" + cfg.authCookieVariableName;

  mkAuthRequestSet =
    header: "auth_request_set $" + header.variableName + " $upstream_http_${header.upstreamHeader};";
  mkProxyHeader = header: "proxy_set_header ${header.proxyHeader} $" + header.variableName + ";";
  authRequestLocationConfig = ''
    auth_request /oauth2/auth;
    error_page 401 = ${cfg.signInLocationName};

    ${lib.concatMapStringsSep "\n" mkAuthRequestSet cfg.authRequestHeaders}
    auth_request_set ${authCookieVariable} $upstream_http_set_cookie;

    ${lib.concatMapStringsSep "\n" mkProxyHeader cfg.authRequestHeaders}
    ${lib.optionalString cfg.clearAuthorizationHeader ''proxy_set_header Authorization "";''}
    add_header Set-Cookie ${authCookieVariable};
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

    ${cfg.signInLocationName} = {
      return = "307 $scheme://$host/oauth2/start?rd=$scheme://$host$request_uri";
      extraConfig = ''
        auth_request off;
      '';
    };
  };

  locationsFor =
    name: oauth2ProxyLocations // cfg.extraLocations // (cfg.extraLocationsByName.${name} or { });
in
{
  options.host.sso.oauth2ProxyGate = {
    enable = lib.mkEnableOption "oauth2-proxy nginx auth_request gate";

    clientId = lib.mkOption {
      type = lib.types.str;
      description = "OIDC client ID used by oauth2-proxy.";
    };

    issuerUrl = lib.mkOption {
      type = lib.types.str;
      default = issuerUrl;
      defaultText = "\${issuerBase}/oauth2/openid/\${clientId}";
      description = "OIDC issuer URL for oauth2-proxy.";
    };

    cookieName = lib.mkOption {
      type = lib.types.str;
      default = "_${safeClientId}_sso";
      description = "Session cookie name used by oauth2-proxy.";
    };

    clientSecretSopsKey = lib.mkOption {
      type = lib.types.str;
      default = "oauth2-proxy/${cfg.clientId}/client_secret";
      description = "SOPS key containing the oauth2-proxy OIDC client secret.";
    };

    cookieSecretSopsKey = lib.mkOption {
      type = lib.types.str;
      default = "oauth2-proxy/${cfg.clientId}/cookie_secret";
      description = "SOPS key containing the oauth2-proxy cookie secret.";
    };

    secretOwner = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Owner for generated oauth2-proxy SOPS secret files.";
    };

    secretGroup = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Group for generated oauth2-proxy SOPS secret files.";
    };

    allowedGroups = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Kanidm groups allowed through oauth2-proxy.";
    };

    groupClaim = lib.mkOption {
      type = lib.types.str;
      description = "OIDC claim containing groups for oauth2-proxy authorization.";
    };

    scope = lib.mkOption {
      type = lib.types.str;
      default = lib.concatStringsSep " " (oidc.scopeWith [ cfg.groupClaim ]);
      description = "OAuth scope requested by oauth2-proxy.";
    };

    whitelistDomains = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Hostnames accepted as oauth2-proxy redirect targets.";
    };

    signInLocationName = lib.mkOption {
      type = lib.types.str;
      default = "@${safeClientId}_oauth2_proxy_sign_in";
      description = "nginx named location used for oauth2-proxy sign-in redirects.";
    };

    authCookieVariableName = lib.mkOption {
      type = lib.types.str;
      default = "${safeClientId}_auth_cookie";
      description = "nginx variable name used to forward oauth2-proxy Set-Cookie headers.";
    };

    authRequestHeaders = lib.mkOption {
      type =
        with lib.types;
        listOf (submodule {
          options = {
            variableName = lib.mkOption {
              type = str;
              description = "nginx variable name assigned from the oauth2-proxy auth response.";
            };

            upstreamHeader = lib.mkOption {
              type = str;
              description = "Lowercase nginx upstream header variable suffix, for example x_auth_request_user.";
            };

            proxyHeader = lib.mkOption {
              type = str;
              description = "Request header forwarded to the protected upstream.";
            };
          };
        });
      default = [
        {
          variableName = "${safeClientId}_user";
          upstreamHeader = "x_auth_request_user";
          proxyHeader = "X-User";
        }
        {
          variableName = "${safeClientId}_email";
          upstreamHeader = "x_auth_request_email";
          proxyHeader = "X-Email";
        }
      ];
      description = "Headers copied from oauth2-proxy auth responses into protected upstream requests.";
    };

    clearAuthorizationHeader = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to clear the Authorization header before proxying to protected upstreams.";
    };

    internalHttpsServiceNames = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "host.internalHttps service names protected by this gate.";
    };

    externalHostNames = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "host.externalService public hostnames protected by this gate.";
    };

    extraLocations = lib.mkOption {
      type = with lib.types; attrsOf anything;
      default = { };
      description = "Extra nginx locations added to every protected vhost.";
    };

    extraLocationsByName = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf anything);
      default = { };
      description = "Extra nginx locations added to one protected internal service or external hostname.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.allowedGroups != [ ];
        message = "host.sso.oauth2ProxyGate.allowedGroups must not be empty when the gate is enabled.";
      }
      {
        assertion = cfg.whitelistDomains != [ ];
        message = "host.sso.oauth2ProxyGate.whitelistDomains must not be empty when the gate is enabled.";
      }
    ];

    sops.secrets.oauth2ProxyGateClientSecret = {
      key = cfg.clientSecretSopsKey;
      owner = cfg.secretOwner;
      group = cfg.secretGroup;
      mode = "0400";
      restartUnits = [ "oauth2-proxy.service" ];
    };

    sops.secrets.oauth2ProxyGateCookieSecret = {
      key = cfg.cookieSecretSopsKey;
      owner = cfg.secretOwner;
      group = cfg.secretGroup;
      mode = "0400";
      restartUnits = [ "oauth2-proxy.service" ];
    };

    services.oauth2-proxy = {
      enable = true;
      provider = "oidc";
      oidcIssuerUrl = cfg.issuerUrl;
      clientID = cfg.clientId;
      clientSecretFile = config.sops.secrets.oauth2ProxyGateClientSecret.path;
      approvalPrompt = "auto";
      cookie = {
        name = cfg.cookieName;
        secretFile = config.sops.secrets.oauth2ProxyGateCookieSecret.path;
      };
      email.domains = [ "*" ];
      scope = cfg.scope;
      upstream = [ "static://202" ];
      reverseProxy = true;
      trustedProxyIP = [
        "127.0.0.1/32"
        "::1/128"
      ];
      setXauthrequest = true;
      passBasicAuth = false;
      extraConfig = {
        allowed-group = cfg.allowedGroups;
        code-challenge-method = "S256";
        oidc-groups-claim = cfg.groupClaim;
        skip-provider-button = true;
        whitelist-domain = cfg.whitelistDomains;
      };
    };

    host.internalHttps.services = lib.genAttrs cfg.internalHttpsServiceNames (_: {
      locationExtraConfig = authRequestLocationConfig;
    });

    host.externalService.virtualHosts = lib.genAttrs cfg.externalHostNames (_: {
      locationExtraConfig = authRequestLocationConfig;
    });

    services.nginx.virtualHosts =
      builtins.listToAttrs (
        map (serviceName: {
          name = "internal-https-${serviceName}";
          value.locations = locationsFor serviceName;
        }) cfg.internalHttpsServiceNames
      )
      // builtins.listToAttrs (
        map (hostName: {
          name = hostName;
          value.locations = locationsFor hostName;
        }) cfg.externalHostNames
      );

    systemd.services.oauth2-proxy = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
