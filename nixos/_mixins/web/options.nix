{
  config,
  lib,
  ...
}:
let
  rootConfig = config;
  metricEndpointName =
    serviceName: metricName:
    if metricName == "default" then serviceName else "${serviceName}-${metricName}";
in
{
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
                        default = "https://${config.serverName}";
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

                      splitDnsHost = lib.mkOption {
                        type = with lib.types; nullOr nonEmptyStr;
                        default = null;
                        description = "Explicit split-DNS host, or null to use the resolved ingress host.";
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

                                bandwidthLimit = lib.mkOption {
                                  type = lib.types.nullOr (
                                    lib.types.submodule {
                                      options = {
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
                                    }
                                  );
                                  default = null;
                                  description = "Shared egress bandwidth limiting for the ${name} route.";
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
              frontend = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.submodule {
                    options = {
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
                  }
                );
                default = null;
                description = "Frontend health probe for ${serviceName}.";
              };

              backend = lib.mkOption {
                type = lib.types.nullOr (
                  lib.types.submodule {
                    options = {
                      path = lib.mkOption {
                        type = lib.types.str;
                        default = "/";
                        description = "Backend health probe path exposed on the probe-only listener.";
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
                  }
                );
                default = null;
                description = "Backend health probe for ${serviceName}.";
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
                requirement = lib.mkOption {
                  type = lib.types.enum [
                    "required"
                    "eligible"
                  ];
                  default = "eligible";
                  description = "Whether an external-probe planner must or may select this service.";
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
              oidcRegistration = lib.mkOption {
                type = with lib.types; nullOr (attrsOf anything);
                default = null;
                description = "OIDC registration contributed by this service.";
              };
              oauth2ProxyGate = lib.mkOption {
                type = with lib.types; nullOr (attrsOf anything);
                default = null;
                description = "oauth2-proxy gate contributed by this service.";
              };
            };

            displayName = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = lib.strings.toSentenceCase serviceName;
              description = "Human-readable service name used by catalogs and monitoring.";
            };

            dashboard = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    id = lib.mkOption {
                      type = lib.types.nonEmptyStr;
                      default = serviceName;
                      description = "Stable identifier used by dashboard catalogs.";
                    };

                    icon = lib.mkOption {
                      type = lib.types.nonEmptyStr;
                      default = "sh:${serviceName}";
                      description = "Dashboard icon identifier or URL.";
                    };
                    section = lib.mkOption {
                      type = lib.types.nonEmptyStr;
                      description = "Dashboard section containing the service.";
                    };
                  };
                }
              );
              default = null;
              description = "Service dashboard entry for ${serviceName}.";
            };
          };
        }
      )
    );
    default = { };
    description = "Canonical declarations for web services hosted by this machine.";
  };

}
