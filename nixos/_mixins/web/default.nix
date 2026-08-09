{
  config,
  hostInventory,
  lib,
  ...
}:
let
  rootConfig = config;
  cfg = rootConfig.host.web;
  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;
  internalServices = lib.filterAttrs (_: service: service.internal.enable) enabledServices;
  metricEndpointName =
    serviceName: metricName:
    if metricName == "default" then serviceName else "${serviceName}-${metricName}";
  enabledMetrics = lib.concatMapAttrs (
    serviceName: service:
    lib.mapAttrs' (
      _: metric:
      lib.nameValuePair metric.endpointName (
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
          inventoryService = hostInventory.servicesById.${serviceName} or null;
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

              endpointName = lib.mkOption {
                type = lib.types.str;
                default = serviceName;
                description = "Host-local internal HTTPS endpoint name.";
              };

              aliases = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Additional internal HTTPS server aliases.";
              };

              publicAliases = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Additional browser-facing sibling vhosts served locally.";
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
                default = if config.public.enable then "mtls" else "none";
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
              enable = lib.mkOption {
                type = lib.types.bool;
                default = inventoryService != null && inventoryService ? publicHost;
                description = "Whether to expose ${serviceName} through public ingress.";
              };

              hostName = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = if inventoryService != null then inventoryService.publicHost or null else null;
                description = "Public DNS hostname served by the ingress host.";
              };

              ingressHost = lib.mkOption {
                type = lib.types.str;
                default = "beast";
                description = "NixOS host providing public ingress for this service.";
              };

              transport = lib.mkOption {
                type = lib.types.enum [
                  "internal-mtls"
                  "direct"
                ];
                default = "internal-mtls";
                description = "Transport used by the public ingress host to reach the service.";
              };

              directUpstream = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Ingress-local upstream URL used by direct public services.";
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

              serveOnOwner = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether the owner host also serves the public hostname as a sibling vhost.";
              };
            };

            health = {
              frontend = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = inventoryService != null && inventoryService.blackboxProbe;
                  description = "Whether to probe the ${serviceName} frontend.";
                };
                path = lib.mkOption {
                  type = lib.types.str;
                  default = if inventoryService == null then "/" else inventoryService.probePath;
                  description = "Frontend health probe path.";
                };
                module = lib.mkOption {
                  type = lib.types.str;
                  default = "http_service";
                  description = "Blackbox exporter module for the frontend probe.";
                };
              };

              backend = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = inventoryService != null && inventoryService ? backendProbe;
                  description = "Whether to probe the ${serviceName} backend.";
                };
                path = lib.mkOption {
                  type = lib.types.str;
                  default =
                    if inventoryService != null && inventoryService ? backendProbe then
                      inventoryService.backendProbe.path
                    else
                      "/";
                  description = "Backend health probe path exposed on the probe-only listener.";
                };
                port = lib.mkOption {
                  type = lib.types.port;
                  default = 9443;
                  description = "Probe-only HTTPS listener port.";
                };
                module = lib.mkOption {
                  type = lib.types.str;
                  default =
                    if inventoryService != null && inventoryService ? backendProbe then
                      inventoryService.backendProbe.blackboxModule or "http_service"
                    else
                      "http_service";
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
                      endpointName = lib.mkOption {
                        type = lib.types.str;
                        default = metricEndpointName serviceName metricName;
                        description = "Host-local mTLS endpoint name.";
                      };
                      openFirewall = lib.mkOption {
                        type = lib.types.bool;
                        default = true;
                        description = "Whether to open the mTLS metrics endpoint in the firewall.";
                      };
                      scrapeInterval = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Optional Prometheus scrape interval.";
                      };
                      discover = lib.mkOption {
                        type = lib.types.bool;
                        default = true;
                        description = "Whether the central Prometheus server should discover this metric automatically.";
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
                default =
                  if inventoryService == null then lib.strings.toSentenceCase serviceName else inventoryService.title;
                description = "Human-readable service title.";
              };
              icon = lib.mkOption {
                type = lib.types.str;
                default = if inventoryService == null then "sh:${serviceName}" else inventoryService.icon;
                description = "Dashboard icon identifier or URL.";
              };
              dashboard = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = inventoryService != null && inventoryService.showInGlance;
                  description = "Whether to show ${serviceName} on the service dashboard.";
                };
                category = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = if inventoryService == null then null else inventoryService.glanceCategory;
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
            assertion =
              !service.public.enable || service.public.transport != "internal-mtls" || service.internal.enable;
            message = "host.web.services.${serviceName} public exposure requires internal HTTPS";
          }
          {
            assertion =
              !service.public.enable
              || service.public.transport != "internal-mtls"
              || service.internal.clientAuth == "mtls";
            message = "host.web.services.${serviceName} public ingress requires an mTLS internal endpoint";
          }
          {
            assertion =
              !service.public.enable
              || service.public.transport != "direct"
              || service.public.directUpstream != null;
            message = "host.web.services.${serviceName} direct public ingress requires directUpstream";
          }
          {
            assertion =
              !service.presentation.dashboard.enable || service.presentation.dashboard.category != null;
            message = "host.web.services.${serviceName} dashboard entries require a category";
          }
        ]) enabledServices
      );
    }

    (lib.mkIf (internalServices != { }) {
      host.internalHttps.services = lib.mapAttrs' (
        _: service:
        lib.nameValuePair service.internal.endpointName {
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
          publicAliases =
            service.internal.publicAliases
            ++ lib.optional (service.public.enable && service.public.serveOnOwner) service.public.hostName;
          mtls.enable = service.internal.clientAuth == "mtls";
          probe = {
            enable = service.health.backend.enable;
            inherit (service.health.backend) port;
          };
        }
      ) internalServices;
    })

    (lib.mkIf (enabledMetrics != { }) {
      host.observability.prometheusEndpoints = lib.mapAttrs (_: metric: {
        enable = true;
        inherit (metric)
          openFirewall
          path
          port
          upstream
          ;
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
