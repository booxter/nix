{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.sso.oauth2ProxyGates;
  oidcBaseScopes = config.host.sso.oidc.baseScopes;
  probeHelpers = import ./oauth2-proxy-gate-probes.nix { inherit lib; };

  gateSubmodule =
    gateName:
    { config, ... }:
    let
      safeClientId = lib.replaceStrings [ "-" ] [ "_" ] config.clientId;
    in
    {
      options = {
        enable = lib.mkEnableOption "oauth2-proxy nginx auth_request gate";

        package = lib.mkPackageOption pkgs "oauth2-proxy" { };

        clientId = lib.mkOption {
          type = lib.types.str;
          description = "OIDC client ID used by oauth2-proxy.";
        };

        displayName = lib.mkOption {
          type = lib.types.str;
          description = "Display name shown by the identity provider.";
        };

        originLanding = lib.mkOption {
          type = lib.types.str;
          description = "Landing page shown for the OIDC client.";
        };

        httpAddress = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:4180";
          description = "Loopback HTTP address where oauth2-proxy listens.";
        };

        serviceName = lib.mkOption {
          type = lib.types.str;
          default = "oauth2-proxy-${gateName}";
          description = "Systemd service name for this oauth2-proxy instance.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = config.serviceName;
          description = "System user that runs this oauth2-proxy instance.";
        };

        group = lib.mkOption {
          type = lib.types.str;
          default = config.user;
          description = "System group that runs this oauth2-proxy instance.";
        };

        cookieName = lib.mkOption {
          type = lib.types.str;
          default = "_${safeClientId}_sso";
          description = "Session cookie name used by oauth2-proxy.";
        };

        sessionRefresh = lib.mkOption {
          type =
            with lib.types;
            nullOr (submodule {
              options = {
                intervalSeconds = lib.mkOption {
                  type = ints.positive;
                  description = "Seconds between oauth2-proxy session refreshes.";
                };

                lifetimeSeconds = lib.mkOption {
                  type = ints.positive;
                  description = "Maximum oauth2-proxy session lifetime in seconds.";
                };

                redisConnectionUrl = lib.mkOption {
                  type = str;
                  description = "Redis connection URL for the oauth2-proxy session store.";
                };

                redisServiceUnit = lib.mkOption {
                  type = str;
                  description = "Systemd unit providing the Redis session store.";
                };
              };
            });
          default = null;
          description = "Redis-backed oauth2-proxy session refresh configuration.";
        };

        clientSecretSopsKey = lib.mkOption {
          type = lib.types.str;
          default = "oauth2-proxy/${config.clientId}/client_secret";
          description = "SOPS key containing the oauth2-proxy OIDC client secret.";
        };

        cookieSecretSopsKey = lib.mkOption {
          type = lib.types.str;
          default = "oauth2-proxy/${config.clientId}/cookie_secret";
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
          default = lib.concatStringsSep " " (oidcBaseScopes ++ [ config.groupClaim ]);
          description = "OAuth scope requested by oauth2-proxy.";
        };

        whitelistDomains = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Hostnames accepted as oauth2-proxy redirect targets.";
        };

        externalOrigin = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Browser-facing origin used for OAuth start, callback, and return URLs when the gate is behind an internal reverse proxy.";
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

        probeLocationsByName = lib.mkOption {
          type = with lib.types; attrsOf (attrsOf anything);
          default = { };
          description = "Extra nginx locations added only to one protected internal service's probe-only HTTPS listener.";
        };
      };
    };

  enabledGates = lib.filterAttrs (_: gate: gate.enable) cfg;
  secretNameFor = gateName: kind: "oauth2-proxy-gate-${gateName}-${kind}";
  originUrlsFor =
    gate:
    if gate.externalOrigin != null then
      [ "${gate.externalOrigin}/oauth2/callback" ]
    else
      lib.unique (
        map (host: "https://${host}/oauth2/callback") gate.externalHostNames
        ++ map (host: "https://${host}/oauth2/callback") (
          lib.concatMap hostInventory.toInternalHttpsServiceHosts gate.internalHttpsServiceNames
        )
      );

  mkArg = name: value: "--${name}=${lib.escapeShellArg (toString value)}";
  mkArgs = name: values: map (mkArg name) values;
  oauth2ProxyArgs =
    gateName: gate:
    let
      oidcClient = config.host.sso.oidc.clients.${gateName};
    in
    [
      (mkArg "approval-prompt" "auto")
      (mkArg "client-id" gate.clientId)
      (mkArg "client-secret-file" "%d/client-secret")
      (mkArg "code-challenge-method" "S256")
      (mkArg "cookie-httponly" "true")
      (mkArg "cookie-name" gate.cookieName)
      (mkArg "cookie-secret-file" "%d/cookie-secret")
      (mkArg "cookie-secure" "true")
      (mkArg "email-domain" "*")
      (mkArg "http-address" gate.httpAddress)
      (mkArg "oidc-groups-claim" gate.groupClaim)
      (mkArg "oidc-issuer-url" oidcClient.issuerUrl)
      (mkArg "pass-access-token" "false")
      (mkArg "pass-basic-auth" "false")
      (mkArg "pass-host-header" "true")
      (mkArg "provider" "oidc")
      (mkArg "proxy-prefix" "/oauth2")
      (mkArg "request-logging" "true")
      (mkArg "reverse-proxy" "true")
      (mkArg "scope" gate.scope)
      (mkArg "set-xauthrequest" "true")
      (mkArg "skip-provider-button" "true")
      (mkArg "upstream" "static://202")
    ]
    ++ lib.optionals (gate.externalOrigin != null) [
      (mkArg "redirect-url" "${gate.externalOrigin}/oauth2/callback")
    ]
    ++ lib.optionals (gate.sessionRefresh != null) [
      (mkArg "cookie-expire" "${toString gate.sessionRefresh.lifetimeSeconds}s")
      (mkArg "cookie-refresh" "${toString gate.sessionRefresh.intervalSeconds}s")
      (mkArg "redis-connection-url" gate.sessionRefresh.redisConnectionUrl)
      (mkArg "session-store-type" "redis")
    ]
    ++ mkArgs "allowed-group" gate.allowedGroups
    ++ mkArgs "trusted-proxy-ip" [
      "127.0.0.1/32"
      "::1/128"
    ]
    ++ mkArgs "whitelist-domain" gate.whitelistDomains;

  mkAuthRequestSet =
    header: "auth_request_set $" + header.variableName + " $upstream_http_${header.upstreamHeader};";
  mkProxyHeader = header: "proxy_set_header ${header.proxyHeader} $" + header.variableName + ";";
  authRequestLocationConfig =
    gate:
    let
      authCookieVariable = "$" + gate.authCookieVariableName;
    in
    ''
      auth_request /oauth2/auth;
      error_page 401 = $sso_oauth2_proxy_auth_failure_uri;

      ${lib.concatMapStringsSep "\n" mkAuthRequestSet gate.authRequestHeaders}
      auth_request_set ${authCookieVariable} $upstream_http_set_cookie;

      ${lib.concatMapStringsSep "\n" mkProxyHeader gate.authRequestHeaders}
      ${lib.optionalString gate.clearAuthorizationHeader ''proxy_set_header Authorization "";''}
      proxy_hide_header X-SSO-Reauth;
      add_header Set-Cookie ${authCookieVariable};
    '';

  oauth2ProxyLocations =
    gate:
    let
      requestOrigin = if gate.externalOrigin != null then gate.externalOrigin else "$scheme://$host";
    in
    {
      "/oauth2/" = {
        proxyPass = gate.httpAddress;
        recommendedProxySettings = true;
        extraConfig = ''
          auth_request off;
          proxy_set_header X-Scheme $scheme;
          proxy_set_header X-Auth-Request-Redirect ${requestOrigin}$request_uri;
        '';
      };

      "= /oauth2/auth" = {
        proxyPass = "${gate.httpAddress}/oauth2/auth";
        recommendedProxySettings = true;
        extraConfig = ''
          internal;
          auth_request off;
          proxy_set_header X-Scheme $scheme;
          proxy_set_header Content-Length "";
          proxy_pass_request_body off;
        '';
      };

      "= /oauth2/session" = {
        proxyPass = "${gate.httpAddress}/oauth2/auth";
        recommendedProxySettings = true;
        extraConfig = ''
          auth_request off;
          proxy_intercept_errors on;
          error_page 401 = /oauth2/reauth-required;
          proxy_set_header X-Scheme $scheme;
          proxy_set_header Content-Length "";
          proxy_pass_request_body off;
          add_header Cache-Control "no-store" always;
        '';
      };

      "= /oauth2/reauth-required" = {
        return = "401";
        extraConfig = ''
          internal;
          auth_request off;
          add_header X-SSO-Reauth "1" always;
          add_header Cache-Control "no-store" always;
          add_header HX-Refresh $sso_oauth2_proxy_hx_refresh always;
        '';
      };
    };

  locationsFor =
    gate: name:
    (oauth2ProxyLocations gate) // gate.extraLocations // (gate.extraLocationsByName.${name} or { });
  # Normal service surfaces that should receive OAuth locations. Example:
  # `search` expands to `internal-https-search` and `search.ihar.dev`.
  internalServiceVhostNames =
    serviceName:
    let
      service = config.host.internalHttps.services.${serviceName};
    in
    [
      "internal-https-${serviceName}"
    ]
    ++ service.publicAliases;
  # OAuth-protected internal HTTPS vhosts. Example: this installs `/oauth2/`,
  # `= /oauth2/auth`, and protected app locations on `internal-https-search`
  # and on its public sibling `search.ihar.dev`.
  protectedInternalVhostsFor =
    gate:
    builtins.listToAttrs (
      builtins.concatMap (
        serviceName:
        map (vhostName: {
          name = vhostName;
          value.locations = locationsFor gate serviceName;
        }) (internalServiceVhostNames serviceName)
      ) gate.internalHttpsServiceNames
    );
  # Public vhosts owned by host.externalService instead of host.internalHttps.
  # Example: Beast's Aurral gate protects the external `au.ihar.dev` vhost.
  protectedExternalVhostsFor =
    gate:
    lib.genAttrs gate.externalHostNames (hostName: {
      locations = locationsFor gate hostName;
    });
in
{
  options.host.sso.oauth2ProxyGates = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }@args: gateSubmodule name args));
    default = { };
    description = "Named oauth2-proxy nginx auth_request gates.";
  };

  config = lib.mkIf (enabledGates != { }) {
    host.sso.oidc.registrations = lib.mapAttrs (gateName: gate: {
      inherit (gate)
        clientId
        displayName
        originLanding
        ;
      originUrls = originUrlsFor gate;
      scopeMaps = lib.genAttrs gate.allowedGroups (_: oidcBaseScopes ++ [ gate.groupClaim ]);
      claimMaps.${gate.groupClaim}.valuesByGroup = lib.genAttrs gate.allowedGroups (group: [ group ]);
      secret = {
        sopsKey = gate.clientSecretSopsKey;
        name = secretNameFor gateName "client-secret";
        owner = gate.secretOwner;
        group = gate.secretGroup;
        restartUnits = [ "${gate.serviceName}.service" ];
      };
    }) enabledGates;

    assertions =
      builtins.concatLists (
        lib.mapAttrsToList (
          gateName: gate:
          [
            {
              assertion = gate.allowedGroups != [ ];
              message = "host.sso.oauth2ProxyGates.${gateName}.allowedGroups must not be empty.";
            }
            {
              assertion = gate.whitelistDomains != [ ];
              message = "host.sso.oauth2ProxyGates.${gateName}.whitelistDomains must not be empty.";
            }
          ]
          ++ lib.optional (gate.sessionRefresh != null) {
            assertion = gate.sessionRefresh.intervalSeconds < gate.sessionRefresh.lifetimeSeconds;
            message = "host.sso.oauth2ProxyGates.${gateName}.sessionRefresh.intervalSeconds must be less than lifetimeSeconds.";
          }
          ++ probeHelpers.assertionsFor gateName gate
        ) enabledGates
      )
      ++ [
        {
          assertion =
            let
              serviceNames = map (gate: gate.serviceName) (builtins.attrValues enabledGates);
            in
            (builtins.length serviceNames) == (builtins.length (lib.unique serviceNames));
          message = "host.sso.oauth2ProxyGates must use unique serviceName values.";
        }
        {
          assertion =
            let
              httpAddresses = map (gate: gate.httpAddress) (builtins.attrValues enabledGates);
            in
            (builtins.length httpAddresses) == (builtins.length (lib.unique httpAddresses));
          message = "host.sso.oauth2ProxyGates must use unique httpAddress values.";
        }
      ];

    users.groups = builtins.listToAttrs (
      map (group: {
        name = group;
        value = { };
      }) (lib.unique (map (gate: gate.group) (builtins.attrValues enabledGates)))
    );

    users.users = builtins.listToAttrs (
      map (user: {
        name = user;
        value = {
          description = "OAuth2 Proxy";
          isSystemUser = true;
          group =
            let
              userGate = lib.findFirst (gate: gate.user == user) null (builtins.attrValues enabledGates);
            in
            userGate.group;
        };
      }) (lib.unique (map (gate: gate.user) (builtins.attrValues enabledGates)))
    );

    sops.secrets = lib.mapAttrs' (
      gateName: gate:
      lib.nameValuePair (secretNameFor gateName "cookie-secret") {
        key = gate.cookieSecretSopsKey;
        owner = gate.secretOwner;
        group = gate.secretGroup;
        mode = "0400";
        restartUnits = [ "${gate.serviceName}.service" ];
      }
    ) enabledGates;

    host.internalHttps.services = lib.mkMerge (
      builtins.concatLists (
        map (gate: [
          (lib.genAttrs gate.internalHttpsServiceNames (_: {
            locationExtraConfig = authRequestLocationConfig gate;
          }))
          # Backend probe bypasses intentionally use a separate listener instead
          # of the normal service vhost. Public ingress forwards to the internal
          # service name, so attaching these locations to :443 would expose them
          # through browser-facing hostnames such as search.ihar.dev.
          (probeHelpers.enableAttrsFor gate)
        ]) (builtins.attrValues enabledGates)
      )
    );

    host.externalService.virtualHosts = lib.mkMerge (
      map (
        gate:
        lib.genAttrs gate.externalHostNames (_: {
          locationExtraConfig = authRequestLocationConfig gate;
        })
      ) (builtins.attrValues enabledGates)
    );

    services.nginx.virtualHosts = lib.mkMerge (
      lib.mapAttrsToList (
        _: gate:
        protectedInternalVhostsFor gate // probeHelpers.vhostsFor gate // protectedExternalVhostsFor gate
      ) enabledGates
    );

    services.nginx.appendHttpConfig = ''
      map $request_method $sso_oauth2_proxy_safe_method {
        default 0;
        GET 1;
        HEAD 1;
      }

      map $http_hx_request $sso_oauth2_proxy_non_htmx {
        default 1;
        ~*^true$ 0;
      }

      map $http_hx_request $sso_oauth2_proxy_hx_refresh {
        default "";
        ~*^true$ true;
      }

      map "$http_sec_fetch_mode:$http_sec_fetch_dest" $sso_oauth2_proxy_document_navigation {
        default 0;
        ~*^navigate:document$ 1;
      }

      map $http_sec_fetch_mode $sso_oauth2_proxy_fetch_metadata_missing {
        default 0;
        "" 1;
      }

      map $http_accept $sso_oauth2_proxy_accepts_html {
        default 0;
        ~*text/html 1;
      }

      map "$sso_oauth2_proxy_safe_method:$sso_oauth2_proxy_non_htmx:$sso_oauth2_proxy_document_navigation:$sso_oauth2_proxy_fetch_metadata_missing:$sso_oauth2_proxy_accepts_html" $sso_oauth2_proxy_auth_failure_uri {
        default /oauth2/reauth-required;
        ~^1:1:1: /oauth2/start;
        "1:1:0:1:1" /oauth2/start;
      }
    '';

    systemd.services = lib.mapAttrs' (
      gateName: gate:
      let
        sessionStoreUnits = lib.optional (gate.sessionRefresh != null) gate.sessionRefresh.redisServiceUnit;
      in
      lib.nameValuePair gate.serviceName {
        description = "OAuth2 Proxy";
        path = [ gate.package ];
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        requires = sessionStoreUnits;
        after = [
          "network-online.target"
          "sops-install-secrets.service"
        ]
        ++ sessionStoreUnits;
        serviceConfig = {
          User = gate.user;
          Group = gate.group;
          ExecStart = "${lib.getExe gate.package} ${lib.concatStringsSep " " (oauth2ProxyArgs gateName gate)}";
          LoadCredential = [
            "client-secret:${config.sops.secrets.${secretNameFor gateName "client-secret"}.path}"
            "cookie-secret:${config.sops.secrets.${secretNameFor gateName "cookie-secret"}.path}"
          ];
          Restart = "always";
        };
      }
    ) enabledGates;
  };
}
