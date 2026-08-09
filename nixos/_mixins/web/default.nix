{
  config,
  lib,
  ...
}:
let
  rootConfig = config;
  cfg = rootConfig.host.web;
  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;
  metricEndpointName =
    serviceName: metricName:
    if metricName == "default" then serviceName else "${serviceName}-${metricName}";
  enabledMetrics = lib.concatMapAttrs (
    serviceName: service:
    lib.mapAttrs' (
      metricName: metric:
      lib.nameValuePair (metricEndpointName serviceName metricName) (
        metric
        // {
          inherit serviceName;
        }
      )
    ) (lib.filterAttrs (_: metric: metric.enable) service.metrics)
  ) enabledServices;
  oidcServices = lib.filterAttrs (_: service: service.auth.mode == "oidc") enabledServices;
  oauth2ProxyServices = lib.filterAttrs (
    _: service: service.auth.mode == "oauth2-proxy"
  ) enabledServices;
in
{
  options.host.web.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        let
          serviceName = name;
        in
        {
          options = {
            enable = lib.mkEnableOption "${serviceName} web service";

            owner = lib.mkOption {
              type = lib.types.str;
              default = cfg.owner;
              readOnly = true;
              internal = true;
              description = "NixOS host publishing this service declaration.";
            };

            upstream = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Local application URL proxied by the internal HTTPS frontend.";
            };

            internal = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether to expose the service through internal HTTPS.";
              };

              serverName = lib.mkOption {
                type = lib.types.str;
                default = "${serviceName}.${rootConfig.host.network.lanDomain}";
                description = "Canonical internal HTTPS server name.";
              };

              aliases = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Additional internal HTTPS server aliases.";
              };

              localAliases = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ serviceName ];
                description = "Single-label and mDNS aliases for the service.";
              };

              listenAddress = lib.mkOption {
                type = lib.types.str;
                default = "0.0.0.0";
                description = "Internal HTTPS listener address.";
              };

              port = lib.mkOption {
                type = lib.types.port;
                default = 443;
                description = "Internal HTTPS listener port.";
              };

              path = lib.mkOption {
                type = lib.types.str;
                default = "/";
                description = "URL path exposed through the internal reverse proxy.";
              };

              clientAuth = lib.mkOption {
                type = lib.types.enum [
                  "none"
                  "mtls"
                ];
                default = "mtls";
                description = "Client authentication required by the internal HTTPS frontend.";
              };

              openFirewall = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether to open the internal HTTPS listener in the firewall.";
              };

              proxyWebsockets = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether nginx should configure websocket proxy headers.";
              };

              recommendedProxySettings = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether nginx recommended proxy settings should be used.";
              };

              locationExtraConfig = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Additional nginx location configuration.";
              };

              secretPrefix = lib.mkOption {
                type = lib.types.str;
                default = "internal_https/${serviceName}";
                description = "SOPS key prefix for the internal HTTPS certificate and key.";
              };

              url = lib.mkOption {
                type = lib.types.str;
                default = "https://${config.internal.serverName}${
                  lib.optionalString (config.internal.port != 443) ":${toString config.internal.port}"
                }";
                readOnly = true;
                internal = true;
                description = "Resolved canonical internal service URL.";
              };
            };

            public = {
              enable = lib.mkEnableOption "public ingress for ${serviceName}";

              hostName = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Public DNS hostname served by the ingress host.";
              };

              ingressHost = lib.mkOption {
                type = lib.types.str;
                default = "beast";
                description = "NixOS host providing public ingress for this service.";
              };

              url = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = if config.public.hostName == null then null else "https://${config.public.hostName}";
                readOnly = true;
                internal = true;
                description = "Resolved public service URL.";
              };

              locationExtraConfig = lib.mkOption {
                type = lib.types.lines;
                default = "";
                description = "Additional public ingress nginx location configuration.";
              };
            };

            health = {
              frontend = {
                enable = lib.mkEnableOption "frontend blackbox probe for ${serviceName}";
                path = lib.mkOption {
                  type = lib.types.str;
                  default = "/";
                  description = "Frontend health probe path.";
                };
                module = lib.mkOption {
                  type = lib.types.str;
                  default = "http_service";
                  description = "Blackbox exporter module for the frontend probe.";
                };
              };

              backend = {
                enable = lib.mkEnableOption "backend blackbox probe for ${serviceName}";
                path = lib.mkOption {
                  type = lib.types.str;
                  default = "/";
                  description = "Backend health probe path exposed on the probe-only listener.";
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  default = 9443;
                  description = "Probe-only HTTPS listener port.";
                };
                module = lib.mkOption {
                  type = lib.types.str;
                  default = "http_service";
                  description = "Blackbox exporter module for the backend probe.";
                };
                title = lib.mkOption {
                  type = lib.types.str;
                  default = "Backend HTTP";
                  description = "Human-readable backend probe name.";
                };
              };
            };

            metrics = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.submodule (
                  { name, ... }:
                  let
                    metricName = name;
                  in
                  {
                    options = {
                      enable = lib.mkEnableOption "${serviceName} ${metricName} Prometheus endpoint";
                      port = lib.mkOption {
                        type = lib.types.port;
                        description = "LAN-visible mTLS metrics port.";
                      };
                      upstream = lib.mkOption {
                        type = lib.types.str;
                        description = "Local HTTP metrics URL proxied by the mTLS endpoint.";
                      };
                      path = lib.mkOption {
                        type = lib.types.str;
                        default = "/metrics";
                        description = "Path exposed by the mTLS metrics endpoint.";
                      };
                      jobName = lib.mkOption {
                        type = lib.types.str;
                        default = if metricName == "default" then serviceName else "${serviceName}-${metricName}";
                        description = "Prometheus scrape job name.";
                      };
                      scrapeInterval = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Optional Prometheus scrape interval.";
                      };
                      labels = lib.mkOption {
                        type = lib.types.attrsOf lib.types.str;
                        default = { };
                        description = "Static labels attached to the Prometheus target.";
                      };
                    };
                  }
                )
              );
              default = { };
              description = "Prometheus endpoints exported by this web service.";
            };

            auth = {
              mode = lib.mkOption {
                type = lib.types.enum [
                  "none"
                  "oidc"
                  "oauth2-proxy"
                ];
                default = "none";
                description = "Authentication integration used by this service.";
              };
              oidcRegistration = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
                description = "OIDC registration contributed when auth.mode is oidc.";
              };
              oauth2ProxyGate = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
                description = "oauth2-proxy gate contributed when auth.mode is oauth2-proxy.";
              };
            };

            presentation = {
              title = lib.mkOption {
                type = lib.types.str;
                default = lib.strings.toSentenceCase serviceName;
                description = "Human-readable service title.";
              };
              icon = lib.mkOption {
                type = lib.types.str;
                default = "sh:${serviceName}";
                description = "Dashboard icon identifier or URL.";
              };
              dashboard = {
                enable = lib.mkEnableOption "dashboard entry for ${serviceName}";
                category = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Dashboard category containing the service.";
                };
              };
            };
          };
        }
      )
    );
    default = { };
    description = "Canonical declarations for web services hosted by this machine.";
  };

  options.host.web.owner = lib.mkOption {
    type = lib.types.str;
    default = config.networking.hostName;
    readOnly = true;
    internal = true;
    description = "Host name attached to locally published web service declarations.";
  };

  config = lib.mkMerge [
    {
      assertions = builtins.concatLists (
        lib.mapAttrsToList (serviceName: service: [
          {
            assertion = !service.enable || !service.internal.enable || service.upstream != null;
            message = "host.web.services.${serviceName}.upstream is required for internal HTTPS exposure";
          }
          {
            assertion = !service.public.enable || service.public.hostName != null;
            message = "host.web.services.${serviceName}.public.hostName is required for public exposure";
          }
          {
            assertion = !service.public.enable || service.internal.enable;
            message = "host.web.services.${serviceName} public exposure requires internal HTTPS";
          }
          {
            assertion = !service.public.enable || service.internal.clientAuth == "mtls";
            message = "host.web.services.${serviceName} public ingress requires an mTLS internal endpoint";
          }
          {
            assertion =
              !service.presentation.dashboard.enable || service.presentation.dashboard.category != null;
            message = "host.web.services.${serviceName} dashboard entries require a category";
          }
        ]) enabledServices
      );
    }

    (lib.mkIf (enabledServices != { }) {
      host.internalHttps.services = lib.mapAttrs (_: service: {
        enable = service.internal.enable;
        inherit (service) upstream;
        inherit (service.internal)
          listenAddress
          localAliases
          locationExtraConfig
          openFirewall
          path
          port
          proxyWebsockets
          recommendedProxySettings
          secretPrefix
          serverName
          ;
        serverAliases = service.internal.aliases;
        publicAliases = lib.optional service.public.enable service.public.hostName;
        mtls.enable = service.internal.clientAuth == "mtls";
        probe = {
          enable = service.health.backend.enable;
          inherit (service.health.backend) port;
        };
      }) enabledServices;
    })

    (lib.mkIf (enabledMetrics != { }) {
      host.observability.prometheusEndpoints = lib.mapAttrs (_: metric: {
        enable = true;
        inherit (metric) path port upstream;
      }) enabledMetrics;
    })

    (lib.mkIf (oidcServices != { }) {
      host.sso.oidc.registrations = lib.mapAttrs (_: service: service.auth.oidcRegistration) oidcServices;
    })

    (lib.mkIf (oauth2ProxyServices != { }) {
      host.sso.oauth2ProxyGates = lib.mapAttrs (
        _: service: service.auth.oauth2ProxyGate
      ) oauth2ProxyServices;
    })
  ];
}
