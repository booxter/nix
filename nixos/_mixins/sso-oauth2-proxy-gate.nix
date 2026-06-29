{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.sso.oauth2ProxyGates;
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };

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

        issuerUrl = lib.mkOption {
          type = lib.types.str;
          default = oidc.openidBaseUrl config.clientId;
          defaultText = "\${issuerBase}/oauth2/openid/\${clientId}";
          description = "OIDC issuer URL for oauth2-proxy.";
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
          default = lib.concatStringsSep " " (oidc.scopeWith [ config.groupClaim ]);
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
    };

  enabledGates = lib.filterAttrs (_: gate: gate.enable) cfg;
  secretNameFor = gateName: kind: "oauth2-proxy-gate-${gateName}-${kind}";

  mkArg = name: value: "--${name}=${lib.escapeShellArg (toString value)}";
  mkArgs = name: values: map (mkArg name) values;
  oauth2ProxyArgs =
    gate:
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
      (mkArg "oidc-issuer-url" gate.issuerUrl)
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
      error_page 401 = ${gate.signInLocationName};

      ${lib.concatMapStringsSep "\n" mkAuthRequestSet gate.authRequestHeaders}
      auth_request_set ${authCookieVariable} $upstream_http_set_cookie;

      ${lib.concatMapStringsSep "\n" mkProxyHeader gate.authRequestHeaders}
      ${lib.optionalString gate.clearAuthorizationHeader ''proxy_set_header Authorization "";''}
      add_header Set-Cookie ${authCookieVariable};
    '';

  oauth2ProxyLocations = gate: {
    "/oauth2/" = {
      proxyPass = gate.httpAddress;
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Auth-Request-Redirect $scheme://$host$request_uri;
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

    ${gate.signInLocationName} = {
      return = "307 $scheme://$host/oauth2/start?rd=$scheme://$host$request_uri";
      extraConfig = ''
        auth_request off;
      '';
    };
  };

  locationsFor =
    gate: name:
    (oauth2ProxyLocations gate) // gate.extraLocations // (gate.extraLocationsByName.${name} or { });
in
{
  options.host.sso.oauth2ProxyGates = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }@args: gateSubmodule name args));
    default = { };
    description = "Named oauth2-proxy nginx auth_request gates.";
  };

  config = lib.mkIf (enabledGates != { }) {
    assertions =
      builtins.concatLists (
        lib.mapAttrsToList (gateName: gate: [
          {
            assertion = gate.allowedGroups != [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.allowedGroups must not be empty.";
          }
          {
            assertion = gate.whitelistDomains != [ ];
            message = "host.sso.oauth2ProxyGates.${gateName}.whitelistDomains must not be empty.";
          }
        ]) enabledGates
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

    sops.secrets =
      lib.mapAttrs' (
        gateName: gate:
        lib.nameValuePair (secretNameFor gateName "client-secret") {
          key = gate.clientSecretSopsKey;
          owner = gate.secretOwner;
          group = gate.secretGroup;
          mode = "0400";
          restartUnits = [ "${gate.serviceName}.service" ];
        }
      ) enabledGates
      // lib.mapAttrs' (
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
      lib.mapAttrsToList (
        _: gate:
        lib.genAttrs gate.internalHttpsServiceNames (_: {
          locationExtraConfig = authRequestLocationConfig gate;
        })
      ) enabledGates
    );

    host.externalService.virtualHosts = lib.mkMerge (
      lib.mapAttrsToList (
        _: gate:
        lib.genAttrs gate.externalHostNames (_: {
          locationExtraConfig = authRequestLocationConfig gate;
        })
      ) enabledGates
    );

    services.nginx.virtualHosts = lib.mkMerge (
      lib.mapAttrsToList (
        _: gate:
        builtins.listToAttrs (
          map (serviceName: {
            name = "internal-https-${serviceName}";
            value.locations = locationsFor gate serviceName;
          }) gate.internalHttpsServiceNames
        )
        // builtins.listToAttrs (
          map (hostName: {
            name = hostName;
            value.locations = locationsFor gate hostName;
          }) gate.externalHostNames
        )
      ) enabledGates
    );

    systemd.services = lib.mapAttrs' (
      gateName: gate:
      lib.nameValuePair gate.serviceName {
        description = "OAuth2 Proxy";
        path = [ gate.package ];
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        after = [
          "network-online.target"
          "sops-install-secrets.service"
        ];
        serviceConfig = {
          User = gate.user;
          Group = gate.group;
          ExecStart = "${lib.getExe gate.package} ${lib.concatStringsSep " " (oauth2ProxyArgs gate)}";
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
