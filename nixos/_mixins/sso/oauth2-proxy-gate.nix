{
  config,
  lib,
  pkgs,
  utils,
  webModel,
  ...
}:
let
  cfg = config.host.sso.oauth2ProxyGates;
  oidcBaseScopes = config.host.sso.oidc.baseScopes;
  gateHelpers = import ./oauth2-proxy-gate-lib.nix { };

  gateSubmodule =
    { ... }:
    {
      options = {
        displayName = lib.mkOption {
          type = lib.types.str;
          description = "Display name shown by the identity provider.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 4180;
          description = "Loopback port where oauth2-proxy listens.";
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

                redisPort = lib.mkOption {
                  type = port;
                  default = 6379;
                  description = "Loopback Redis port for the oauth2-proxy session store.";
                };
              };
            });
          default = null;
          description = "Redis-backed oauth2-proxy session refresh configuration.";
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

        externalOrigin = lib.mkOption {
          type = with lib.types; nullOr (strMatching "^https://[^/?#]+$");
          default = null;
          description = "Pathless HTTPS origin used for OAuth start, callback, and return URLs when the gate is behind an internal reverse proxy.";
        };

        authRequestHeaders = lib.mkOption {
          type = with lib.types; attrsOf nonEmptyStr;
          default = {
            X-User = "x_auth_request_user";
            X-Email = "x_auth_request_email";
          };
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
          description = "Internal web endpoint names protected by this gate.";
        };

      };
    };

  gates = cfg;
  secretNameFor = gateName: kind: "oauth2-proxy-gate-${gateName}-${kind}";
  serviceNameFor = gateName: "oauth2-proxy-${gateName}";
  credentialDirectoryPlaceholder = "@oauth2-proxy-credentials@";
  credentialPath = name: "${credentialDirectoryPlaceholder}/${name}";
  safeName = name: lib.replaceStrings [ "-" ] [ "_" ] (lib.toLower name);
  cookieNameFor = gateName: "_${lib.replaceStrings [ "-" ] [ "_" ] gateName}_sso";
  httpAddressFor = gate: "http://127.0.0.1:${toString gate.port}";
  logoutCompletePath = "/oauth2/logout-complete";
  internalHttpsServiceHosts =
    endpointName:
    let
      service = webModel.internalEndpoints.${endpointName};
    in
    [
      service.internal.serverName
      endpointName
      "${endpointName}.local"
    ]
    ++ service.internal.serverAliases
    ++ service.internal.publicAliases;
  browserOriginFor =
    gate:
    if gate.externalOrigin != null then
      gate.externalOrigin
    else
      let
        endpointName = builtins.head gate.internalHttpsServiceNames;
      in
      "https://${webModel.internalEndpoints.${endpointName}.internal.serverName}";
  whitelistDomainsFor =
    gate:
    if gate.externalOrigin != null then
      [ (lib.removePrefix "https://" gate.externalOrigin) ]
    else
      lib.unique (lib.concatMap internalHttpsServiceHosts gate.internalHttpsServiceNames);
  originUrlsFor =
    gate:
    if gate.externalOrigin != null then
      [ "${gate.externalOrigin}/oauth2/callback" ]
    else
      lib.unique (
        map (host: "https://${host}/oauth2/callback") (
          lib.concatMap internalHttpsServiceHosts gate.internalHttpsServiceNames
        )
      );

  mkArg = name: value: "--${name}=${toString value}";
  mkArgs = name: values: map (mkArg name) values;
  oauth2ProxyArgs =
    gateName: gate:
    let
      oidcClient = config.host.sso.oidc.clients.${gateName};
    in
    [
      (mkArg "approval-prompt" "auto")
      (mkArg "client-id" gateName)
      (mkArg "client-secret-file" (credentialPath "client-secret"))
      (mkArg "code-challenge-method" "S256")
      (mkArg "cookie-httponly" "true")
      (mkArg "cookie-name" (cookieNameFor gateName))
      (mkArg "cookie-secret-file" (credentialPath "cookie-secret"))
      (mkArg "cookie-secure" "true")
      (mkArg "email-domain" "*")
      (mkArg "http-address" (httpAddressFor gate))
      (mkArg "oidc-groups-claim" gate.groupClaim)
      (mkArg "oidc-issuer-url" oidcClient.issuerUrl)
      (mkArg "pass-access-token" "false")
      (mkArg "pass-basic-auth" "false")
      (mkArg "pass-host-header" "true")
      (mkArg "provider" "oidc")
      (mkArg "proxy-prefix" "/oauth2")
      (mkArg "request-logging" "true")
      (mkArg "reverse-proxy" "true")
      (mkArg "scope" (lib.concatStringsSep " " (oidcBaseScopes ++ [ gate.groupClaim ])))
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
      (mkArg "redis-connection-url" (gateHelpers.redisConnectionUrl gate))
      (mkArg "session-store-type" "redis")
    ]
    ++ mkArgs "allowed-group" gate.allowedGroups
    ++ mkArgs "trusted-proxy-ip" [
      "127.0.0.1/32"
      "::1/128"
    ]
    ++ mkArgs "whitelist-domain" (whitelistDomainsFor gate);
  authRequestVariable = gateName: proxyHeader: "${safeName gateName}_${safeName proxyHeader}";
  mkAuthRequestSet =
    gateName: proxyHeader: upstreamHeader:
    "auth_request_set $"
    + authRequestVariable gateName proxyHeader
    + " $upstream_http_${upstreamHeader};";
  mkProxyHeader =
    gateName: proxyHeader: _:
    "proxy_set_header ${proxyHeader} $" + authRequestVariable gateName proxyHeader + ";";
  authRequestLocationConfig =
    gateName: gate:
    let
      authCookieVariable = "$" + safeName gateName + "_auth_cookie";
    in
    ''
      auth_request /oauth2/auth;
      error_page 401 = $sso_oauth2_proxy_auth_failure_uri;

      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (mkAuthRequestSet gateName) gate.authRequestHeaders
      )}
      auth_request_set ${authCookieVariable} $upstream_http_set_cookie;

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (mkProxyHeader gateName) gate.authRequestHeaders)}
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
        proxyPass = httpAddressFor gate;
        recommendedProxySettings = true;
        extraConfig = ''
          auth_request off;
          proxy_set_header X-Scheme $scheme;
          proxy_set_header X-Auth-Request-Redirect ${requestOrigin}$request_uri;
        '';
      };

      "= /oauth2/auth" = {
        proxyPass = "${httpAddressFor gate}/oauth2/auth";
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
        proxyPass = "${httpAddressFor gate}/oauth2/auth";
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

  sessionClearLocations =
    gate: endpointName:
    let
      paths = webModel.internalEndpoints.${endpointName}.auth.sessionClearPaths;
    in
    lib.optionalAttrs (paths != [ ]) (
      builtins.listToAttrs (
        map (path: {
          name = "= ${path}";
          value = {
            proxyPass = "${httpAddressFor gate}/oauth2/sign_out?rd=${logoutCompletePath}";
            recommendedProxySettings = true;
            extraConfig = ''
              auth_request off;
            '';
          };
        }) paths
      )
      // {
        "= ${logoutCompletePath}" = {
          return = "204";
          extraConfig = ''
            auth_request off;
          '';
        };
      }
    );

  locationsFor =
    gate: endpointName: (oauth2ProxyLocations gate) // (sessionClearLocations gate endpointName);
  # Normal service surfaces that should receive OAuth locations. Example:
  # `search` expands to `internal-https-search` and `search.ihar.dev`.
  internalServiceVhostNames =
    endpointName:
    let
      service = webModel.internalEndpoints.${endpointName};
    in
    [
      "internal-https-${service.internal.endpointName}"
    ]
    ++ service.internal.publicAliases;
  # OAuth-protected internal HTTPS vhosts. Example: this installs `/oauth2/`,
  # `= /oauth2/auth`, and protected app locations on `internal-https-search`
  # and on its public sibling `search.ihar.dev`.
  protectedInternalVhostsFor =
    gateName: gate:
    builtins.listToAttrs (
      builtins.concatMap (
        endpointName:
        let
          service = webModel.internalEndpoints.${endpointName};
          locations = lib.recursiveUpdate (locationsFor gate endpointName) {
            ${service.internal.path}.extraConfig = authRequestLocationConfig gateName gate;
          };
        in
        map (vhostName: {
          name = vhostName;
          value = { inherit locations; };
        }) (internalServiceVhostNames endpointName)
      ) gate.internalHttpsServiceNames
    );
in
{
  imports = [ ./oauth2-proxy-gate/assertions.nix ];

  options.host.sso.oauth2ProxyGates = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule gateSubmodule);
    default = { };
    description = "Named oauth2-proxy nginx auth_request gates.";
  };

  config = lib.mkIf (gates != { }) {
    host.sso.oidc.registrations = lib.mapAttrs (gateName: gate: {
      inherit (gate)
        displayName
        ;
      originLanding = "${browserOriginFor gate}/";
      originUrls = originUrlsFor gate;
      scopeMaps = lib.genAttrs gate.allowedGroups (_: oidcBaseScopes ++ [ gate.groupClaim ]);
      claimMaps.${gate.groupClaim}.valuesByGroup = lib.genAttrs gate.allowedGroups (group: [ group ]);
      secret = {
        sopsKey = "oauth2-proxy/${gateName}/client_secret";
        name = secretNameFor gateName "client-secret";
        restartUnits = [ "${serviceNameFor gateName}.service" ];
      };
    }) gates;

    users.groups = lib.genAttrs (map serviceNameFor (builtins.attrNames gates)) (_: { });

    users.users = lib.genAttrs (map serviceNameFor (builtins.attrNames gates)) (user: {
      description = "OAuth2 Proxy";
      isSystemUser = true;
      group = user;
    });

    sops.secrets = lib.mapAttrs' (
      gateName: _gate:
      lib.nameValuePair (secretNameFor gateName "cookie-secret") {
        key = "oauth2-proxy/${gateName}/cookie_secret";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "${serviceNameFor gateName}.service" ];
      }
    ) gates;

    services.nginx.virtualHosts = lib.mkMerge (lib.mapAttrsToList protectedInternalVhostsFor gates);

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
        sessionStoreUnits = lib.optional (gate.sessionRefresh != null) (
          gateHelpers.redisServiceUnit gateName
        );
      in
      lib.nameValuePair (serviceNameFor gateName) {
        description = "OAuth2 Proxy";
        path = [ pkgs.oauth2-proxy ];
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
          User = serviceNameFor gateName;
          Group = serviceNameFor gateName;
          ExecStart = lib.replaceStrings [ credentialDirectoryPlaceholder ] [ "%d" ] (
            utils.escapeSystemdExecArgs ([ (lib.getExe pkgs.oauth2-proxy) ] ++ oauth2ProxyArgs gateName gate)
          );
          LoadCredential = [
            "client-secret:${config.sops.secrets.${secretNameFor gateName "client-secret"}.path}"
            "cookie-secret:${config.sops.secrets.${secretNameFor gateName "cookie-secret"}.path}"
          ];
          Restart = "always";
        };
      }
    ) gates;
  };
}
