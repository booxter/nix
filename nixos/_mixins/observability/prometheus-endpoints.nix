{
  config,
  lib,
  ...
}:
let
  cfg = config.host.observability;
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  endpoints = cfg.prometheusEndpoints;
  discoveredEndpoints = lib.filterAttrs (_: endpoint: endpoint.scrape != null) endpoints;
  endpointSecretAttrName = endpointName: "prometheus-mtls-${endpointName}";
  endpointPortValues = map (endpoint: endpoint.port) (builtins.attrValues endpoints);
in
{
  options.host.observability = {
    prometheusEndpoints = lib.mkOption {
      type =
        with lib.types;
        attrsOf (
          submodule (
            { name, ... }:
            {
              options = {
                listenAddress = lib.mkOption {
                  type = str;
                  default = "0.0.0.0";
                  description = "Address for the mTLS endpoint to bind.";
                };

                port = lib.mkOption {
                  type = port;
                  description = "LAN-visible port for the mTLS endpoint.";
                };

                path = lib.mkOption {
                  type = str;
                  default = "/metrics";
                  description = "HTTP path exposed by the mTLS endpoint.";
                };

                upstream = lib.mkOption {
                  type = str;
                  description = "Upstream URL that nginx proxies to after mTLS auth.";
                };

                openFirewall = lib.mkOption {
                  type = bool;
                  default = true;
                  description = "Whether to open the firewall for the mTLS endpoint.";
                };

                serverName = lib.mkOption {
                  type = str;
                  default = config.networking.hostName;
                  description = "Server name presented by the nginx vhost for this endpoint.";
                };

                secretPrefix = lib.mkOption {
                  type = str;
                  default = "prometheus/${name}";
                  description = "Secret prefix containing server_crt_unencrypted and server_key for this endpoint.";
                };

                scrape = lib.mkOption {
                  type = nullOr (submodule {
                    options = {
                      jobName = lib.mkOption {
                        type = str;
                        default = name;
                        description = "Prometheus scrape job name.";
                      };

                      profile = lib.mkOption {
                        type = str;
                        default = "infrastructure";
                        description = "Semantic scrape policy consumed by alerts and dashboards.";
                      };

                      component = lib.mkOption {
                        type = str;
                        default = name;
                        description = "Component producing the metrics.";
                      };

                      service = lib.mkOption {
                        type = nullOr str;
                        default = null;
                        description = "Fleet web service represented by the endpoint, when applicable.";
                      };

                      availability = lib.mkOption {
                        type = enum [
                          "always"
                          "intermittent"
                        ];
                        default = if config.host.hardware.isLaptop then "intermittent" else "always";
                        description = "Availability policy for this scrape target.";
                      };

                      interval = lib.mkOption {
                        type = nullOr str;
                        default = null;
                        description = "Optional Prometheus scrape interval.";
                      };

                      labels = lib.mkOption {
                        type = attrsOf str;
                        default = { };
                        description = "Additional static labels attached to this target.";
                      };

                      metricRelabelConfigs = lib.mkOption {
                        type = listOf attrs;
                        default = [ ];
                        description = "Metric relabeling rules supplied by the endpoint owner.";
                      };
                    };
                  });
                  default = null;
                  description = "Optional central Prometheus discovery policy for this endpoint.";
                };
              };
            }
          )
        );
      default = { };
      description = "Nginx-fronted mTLS endpoints for remote Prometheus scrapes.";
    };

  };

  config = lib.mkIf (cfg.enable && endpoints != { }) {
    host.observability.inventory.endpoints = lib.mapAttrs (_name: endpoint: {
      inherit (endpoint) path;
      inherit (endpoint.scrape)
        interval
        jobName
        metricRelabelConfigs
        ;
      target = "${config.networking.hostName}:${toString endpoint.port}";
      labels = {
        inherit (endpoint.scrape) availability component;
        instance = config.networking.hostName;
        realm = config.host.realm;
        scrape_profile = endpoint.scrape.profile;
      }
      // lib.optionalAttrs (endpoint.scrape.service != null) {
        service = endpoint.scrape.service;
      }
      // endpoint.scrape.labels;
    }) discoveredEndpoints;

    host.pki.certificates = lib.mapAttrs' (
      name: endpoint:
      lib.nameValuePair "observability_endpoint_server/${name}" {
        commonName = "prometheus-${name}.${config.networking.hostName}";
        inherit (endpoint) port secretPrefix;
        sans = config.host.network.certificateDnsNames;
      }
    ) endpoints;

    assertions = [
      {
        assertion =
          (builtins.length endpointPortValues) == (builtins.length (lib.unique endpointPortValues));
        message = "host.observability.prometheusEndpoints must not reuse listen ports on the same host.";
      }
    ];

    sops.secrets =
      lib.mapAttrs' (
        endpointName: endpoint:
        lib.nameValuePair "${endpointSecretAttrName endpointName}-server-crt" {
          key = "${endpoint.secretPrefix}/server_crt_unencrypted";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        }
      ) endpoints
      // lib.mapAttrs' (
        endpointName: endpoint:
        lib.nameValuePair "${endpointSecretAttrName endpointName}-server-key" {
          key = "${endpoint.secretPrefix}/server_key";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        }
      ) endpoints;

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = lib.mapAttrs' (
        endpointName: endpoint:
        lib.nameValuePair "prometheus-mtls-${endpointName}" {
          serverName = endpoint.serverName;
          onlySSL = true;
          listen = [
            {
              addr = endpoint.listenAddress;
              port = endpoint.port;
              ssl = true;
            }
          ];
          sslCertificate = config.sops.secrets."${endpointSecretAttrName endpointName}-server-crt".path;
          sslCertificateKey = config.sops.secrets."${endpointSecretAttrName endpointName}-server-key".path;
          sslTrustedCertificate = pkiRootCaPath;
          extraConfig = ''
            ssl_client_certificate ${pkiRootCaPath};
            ssl_verify_client on;
          '';
          locations.${endpoint.path}.proxyPass = endpoint.upstream;
        }
      ) endpoints;
    };

    networking.firewall.allowedTCPPorts = lib.unique (
      builtins.concatMap (endpoint: lib.optional endpoint.openFirewall endpoint.port) (
        builtins.attrValues endpoints
      )
    );

    systemd.services.nginx = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
