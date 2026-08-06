{
  config,
  hostInventory,
  hostSpec,
  lib,
  ...
}:
let
  cfg = config.host.observability;
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  enabledEndpoints = lib.filterAttrs (_: endpoint: endpoint.enable) cfg.prometheusEndpoints;
  endpointSecretAttrName = endpointName: "prometheus-mtls-${endpointName}";
  endpointPortValues = map (endpoint: endpoint.port) (builtins.attrValues enabledEndpoints);
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
                enable = lib.mkEnableOption "mTLS-protected Prometheus scrape endpoint";

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

                sans = lib.mkOption {
                  type = listOf str;
                  default = cfg.prometheusEndpointSans;
                  description = "DNS SANs to include when issuing this endpoint certificate.";
                };

                secretPrefix = lib.mkOption {
                  type = str;
                  default = "prometheus/${name}";
                  description = "Secret prefix containing server_crt_unencrypted and server_key for this endpoint.";
                };

                locationExtraConfig = lib.mkOption {
                  type = lines;
                  default = "";
                  description = "Extra nginx location config for this endpoint.";
                };
              };
            }
          )
        );
      default = { };
      description = "Nginx-fronted mTLS endpoints for remote Prometheus scrapes.";
    };

    prometheusEndpointSans = lib.mkOption {
      type = with lib.types; listOf str;
      default = hostInventory.toNixosHostCertificateDnsNames hostSpec;
      description = "Default DNS SANs for host-level Prometheus mTLS server certificates.";
    };
  };

  config = lib.mkIf (cfg.enable && enabledEndpoints != { }) {
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
      ) enabledEndpoints
      // lib.mapAttrs' (
        endpointName: endpoint:
        lib.nameValuePair "${endpointSecretAttrName endpointName}-server-key" {
          key = "${endpoint.secretPrefix}/server_key";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        }
      ) enabledEndpoints;

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
          sslTrustedCertificate = internalPkiRootCaPath;
          extraConfig = ''
            ssl_client_certificate ${internalPkiRootCaPath};
            ssl_verify_client on;
          '';
          locations.${endpoint.path} = {
            proxyPass = endpoint.upstream;
            extraConfig = endpoint.locationExtraConfig;
          };
        }
      ) enabledEndpoints;
    };

    networking.firewall.allowedTCPPorts = lib.unique (
      builtins.concatMap (endpoint: lib.optional endpoint.openFirewall endpoint.port) (
        builtins.attrValues enabledEndpoints
      )
    );

    systemd.services.nginx = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
