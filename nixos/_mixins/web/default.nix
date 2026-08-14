{
  config,
  lib,
  ...
}:
let
  rootConfig = config;
  cfg = rootConfig.host.web;
  services = cfg.services;
  internalServices = lib.filterAttrs (_: service: service.internal != null) services;
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
          serviceAvailability = service.observability.availability;
        }
      )
    ) (lib.filterAttrs (_: metric: metric.enable) service.metrics)
  ) services;
  oidcServices = lib.filterAttrs (_: service: service.auth.mode == "oidc") services;
  oauth2ProxyServices = lib.filterAttrs (_: service: service.auth.mode == "oauth2-proxy") services;
in
{
  imports = [
    ./api.nix
    ./assertions.nix
    ./ingress
  ];

  options.host.web.services = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, config, ... }:
        let
          serviceName = name;
          service = config;
        in
        {
          options = {
            owner = lib.mkOption {
              type = lib.types.str;
              default = cfg.owner;
              readOnly = true;
              internal = true;
              description = "NixOS host publishing this service declaration.";
            };

            upstream = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Local application URL exposed by this service.";
            };

            internal = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule (
                  { config, ... }:
                  {
                    options = {
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
                        default = if service.public != null then "mtls" else "none";
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
                        default = "https://${config.serverName}${
                          lib.optionalString (config.port != 443) ":${toString config.port}"
                        }";
                        readOnly = true;
                        internal = true;
                        description = "Resolved canonical internal service URL.";
                      };
                    };
                  }
                )
              );
              default = { };
              description = "Internal HTTPS exposure for this service.";
            };

            public = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule (
                  { config, ... }:
                  {
                    options = {
                      hostName = lib.mkOption {
                        type = lib.types.nonEmptyStr;
                        description = "Public DNS hostname served by the ingress host.";
                      };

                      ingressHost = lib.mkOption {
                        type = with lib.types; nullOr nonEmptyStr;
                        default = null;
                        description = "Explicit public ingress host, or null to use the realm controller.";
                      };

                      splitDnsHost = lib.mkOption {
                        type = with lib.types; nullOr nonEmptyStr;
                        default = null;
                        description = "Explicit split-DNS host, or null to use the resolved ingress host.";
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
                        type = lib.types.str;
                        default = "https://${config.hostName}";
                        readOnly = true;
                        internal = true;
                        description = "Resolved public service URL.";
                      };

                      locationExtraConfig = lib.mkOption {
                        type = lib.types.lines;
                        default = "";
                        description = "Additional public ingress nginx location configuration.";
                      };

                      routes = lib.mkOption {
                        type = lib.types.attrsOf (
                          lib.types.submodule (
                            { name, ... }:
                            {
                              options = {
                                location = lib.mkOption {
                                  type = lib.types.nonEmptyStr;
                                  description = "nginx location expression for the ${name} public route.";
                                };

                                upstream = lib.mkOption {
                                  type = with lib.types; nullOr nonEmptyStr;
                                  default = null;
                                  description = "Route-specific upstream URL, or null to use the service public upstream.";
                                };

                                proxyWebsockets = lib.mkOption {
                                  type = lib.types.bool;
                                  default = false;
                                  description = "Whether the ${name} public route proxies WebSocket connections.";
                                };

                                bandwidthLimit = {
                                  enable = lib.mkEnableOption "shared egress bandwidth limiting for the ${name} route";

                                  listenPort = lib.mkOption {
                                    type = lib.types.port;
                                    description = "Ingress-local HAProxy port used for the ${name} route.";
                                  };

                                  bytesPerSecond = lib.mkOption {
                                    type = lib.types.ints.positive;
                                    description = "Aggregate external response bandwidth allowed for the ${name} route.";
                                  };

                                  unlimitedCidrs = lib.mkOption {
                                    type = with lib.types; listOf nonEmptyStr;
                                    default = [
                                      "127.0.0.0/8"
                                      "::1"
                                      "fe80::/10"
                                      "fc00::/7"
                                    ];
                                    description = "Client networks excluded from the ${name} route bandwidth limit.";
                                  };
                                };
                              };
                            }
                          )
                        );
                        default = { };
                        description = "Additional structured routes served by public ingress.";
                      };

                      serveOnOwner = lib.mkOption {
                        type = lib.types.bool;
                        default = true;
                        description = "Whether the owner host also serves the public hostname as a sibling vhost.";
                      };
                    };
                  }
                )
              );
              default = null;
              description = "Public HTTPS exposure for this service.";
            };

            health = {
              frontend = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether to probe the ${serviceName} frontend.";
                };
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
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether to probe the ${serviceName} backend.";
                };
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

                upstreamPath = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  internal = true;
                  description = "Backend path used when the public probe path is an alias.";
                };

                recommendedProxySettings = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  internal = true;
                };

                allowedMethods = lib.mkOption {
                  type = with lib.types; listOf nonEmptyStr;
                  default = [ ];
                  internal = true;
                };

                locationExtraConfig = lib.mkOption {
                  type = lib.types.lines;
                  default = "";
                  internal = true;
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

            observability = {
              availability = lib.mkOption {
                type = lib.types.enum [
                  "always"
                  "intermittent"
                ];
                default = if rootConfig.host.hardware.isLaptop then "intermittent" else "always";
                description = "Availability policy inherited by this service's metrics and probes.";
              };

              importance = lib.mkOption {
                type = lib.types.enum [
                  "critical"
                  "important"
                  "normal"
                  "best-effort"
                ];
                default = "normal";
                description = "Operational importance used to prioritize capacity-limited monitoring.";
              };

              externalProbe = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = config.public != null && config.health.frontend.enable;
                  description = "Whether this public frontend is eligible for external probing.";
                };

                requirement = lib.mkOption {
                  type = lib.types.enum [
                    "required"
                    "eligible"
                    "disabled"
                  ];
                  default = "eligible";
                  description = "Whether an external-probe planner must, may, or must not select this service.";
                };
              };
            };

            auth = {
              policy = lib.mkOption {
                type = with lib.types; nullOr (enum [ "media-admin" ]);
                default = null;
                description = "Named access policy protecting this web service.";
              };

              sessionClearPaths = lib.mkOption {
                type = with lib.types; listOf (strMatching "^/.*");
                default = [ ];
                internal = true;
                description = "Application logout paths that clear the proxy session.";
              };
              mode = lib.mkOption {
                type = lib.types.enum [
                  "none"
                  "oidc"
                  "oauth2-proxy"
                ];
                default = "none";
                description = "Authentication integration used by this service.";
              };
              registrationName = lib.mkOption {
                type = lib.types.str;
                default = serviceName;
                description = "Name used for the compiled OIDC registration or oauth2-proxy gate.";
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

            displayName = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = lib.strings.toSentenceCase serviceName;
              description = "Human-readable service name used by catalogs and monitoring.";
            };

            dashboard = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Whether to show ${serviceName} on the service dashboard.";
              };
              icon = lib.mkOption {
                type = lib.types.nonEmptyStr;
                default = "sh:${serviceName}";
                description = "Dashboard icon identifier or URL.";
              };
              section = lib.mkOption {
                type = with lib.types; nullOr nonEmptyStr;
                default = null;
                description = "Dashboard section containing the service.";
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
      host.network.stableAddress.requiredBy = lib.optional (
        internalServices != { }
      ) "internal web service DNS";

    }

    (lib.mkIf (internalServices != { }) {
      host.internalHttps.services = lib.mapAttrs' (
        _: service:
        lib.nameValuePair service.internal.endpointName {
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
            ++ lib.optional (service.public != null && service.public.serveOnOwner) service.public.hostName;
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
        inherit (metric)
          openFirewall
          path
          port
          upstream
          ;
        scrape =
          if metric.discover then
            {
              inherit (metric) jobName labels;
              profile = "application";
              component = metric.serviceName;
              service = metric.serviceName;
              availability = metric.serviceAvailability;
              interval = metric.scrapeInterval;
            }
          else
            null;
      }) enabledMetrics;
    })

    (lib.mkIf (oidcServices != { }) {
      host.sso.oidc.registrations = lib.mapAttrs' (
        _: service: lib.nameValuePair service.auth.registrationName service.auth.oidcRegistration
      ) oidcServices;
    })

    (lib.mkIf (oauth2ProxyServices != { }) {
      host.sso.oauth2ProxyGates = lib.mapAttrs' (
        _: service: lib.nameValuePair service.auth.registrationName service.auth.oauth2ProxyGate
      ) oauth2ProxyServices;
    })
  ];
}
