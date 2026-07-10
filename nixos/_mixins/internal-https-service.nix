{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.internalHttps;
  internalPkiRootCaPath = import ../../lib/home-internal-pki-root-ca.nix;
  localServerAliasesFor = aliases: aliases ++ builtins.map hostInventory.toLocalDnsName aliases;
  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;
  enabledServerNames = builtins.concatMap (service: [ service.serverName ] ++ service.serverAliases) (
    builtins.attrValues enabledServices
  );
  enabledMtlsClients = lib.filterAttrs (_: client: client.enable) cfg.mtlsClients;
  secretAttrName = serviceName: "internal-https-${serviceName}";
  mtlsClientSecretAttrName = clientName: "internal-https-client-${clientName}";
in
{
  options.host.internalHttps.localAliases = lib.mkOption {
    type = with lib.types; listOf str;
    default = [ ];
    description = "Single-label local service names exported by enabled internal HTTPS services.";
  };

  options.host.internalHttps.mtlsClients = lib.mkOption {
    type =
      with lib.types;
      attrsOf (
        submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "internal HTTPS mTLS client identity";

              secretPrefix = lib.mkOption {
                type = str;
                default = "internal_https/clients/${name}";
                description = "SOPS key prefix containing client_crt_unencrypted and client_key for this client identity.";
              };

              commonName = lib.mkOption {
                type = str;
                default = "${name}.${config.host.dnsName}";
                description = "Leaf certificate common name to issue for this client identity.";
              };

              sans = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Optional SANs for this client certificate.";
              };

              owner = lib.mkOption {
                type = str;
                default = "root";
                description = "Owner for generated client certificate and key secret files.";
              };

              group = lib.mkOption {
                type = str;
                default = "root";
                description = "Group for generated client certificate and key secret files.";
              };

              mode = lib.mkOption {
                type = str;
                default = "0400";
                description = "Mode for generated client certificate and key secret files.";
              };

              restartUnits = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Systemd units restarted when this client certificate changes.";
              };
            };
          }
        )
      );
    default = { };
    description = "Internal HTTPS mTLS client identities used by services on this host.";
  };

  options.host.internalHttps.services = lib.mkOption {
    type =
      with lib.types;
      attrsOf (
        submodule (
          { name, config, ... }:
          {
            config.serverAliases = lib.mkBefore (localServerAliasesFor config.localAliases);

            options = {
              enable = lib.mkEnableOption "internal HTTPS service";

              serverName = lib.mkOption {
                type = str;
                default = "${name}.${hostInventory.site.lan.domain}";
                description = "DNS name presented by the internal HTTPS vhost.";
              };

              serverAliases = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ ];
                description = "Additional hostnames served by the internal HTTPS vhost.";
              };

              sans = lib.mkOption {
                type = with lib.types; listOf str;
                default = lib.unique (
                  [
                    name
                    config.serverName
                  ]
                  ++ config.serverAliases
                );
                description = "DNS SANs to include when issuing this service certificate.";
              };

              localAliases = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ name ];
                description = "Single-label local service names to serve directly and as .local mDNS names.";
              };

              listenAddress = lib.mkOption {
                type = str;
                default = "0.0.0.0";
                description = "Address for the internal HTTPS vhost to bind.";
              };

              port = lib.mkOption {
                type = port;
                default = 443;
                description = "Port for the internal HTTPS vhost.";
              };

              path = lib.mkOption {
                type = str;
                default = "/";
                description = "Path to expose through the HTTPS reverse proxy.";
              };

              upstream = lib.mkOption {
                type = str;
                description = "Loopback or private upstream URL for the internal HTTPS service.";
              };

              openFirewall = lib.mkOption {
                type = bool;
                default = true;
                description = "Whether to open the firewall for the internal HTTPS service.";
              };

              proxyWebsockets = lib.mkOption {
                type = bool;
                default = true;
                description = "Whether to enable websocket proxy headers.";
              };

              recommendedProxySettings = lib.mkOption {
                type = bool;
                default = true;
                description = "Whether to apply NixOS nginx recommended proxy headers automatically.";
              };

              secretPrefix = lib.mkOption {
                type = str;
                default = "internal_https/${name}";
                description = "SOPS key prefix containing server_crt_unencrypted and server_key for this service.";
              };

              locationExtraConfig = lib.mkOption {
                type = lines;
                default = "";
                description = "Extra nginx location config for this service.";
              };

              mtls = {
                enable = lib.mkEnableOption "client certificate authentication for this internal HTTPS service";

                trustedCaCertificate = lib.mkOption {
                  type = path;
                  default = internalPkiRootCaPath;
                  description = "CA certificate bundle trusted for inbound client certificate verification.";
                };
              };
            };
          }
        )
      );
    default = { };
    description = "Internal HTTPS services fronted by nginx and backed by the internal PKI.";
  };

  config = lib.mkIf (enabledServices != { } || enabledMtlsClients != { }) {
    host.internalHttps.localAliases = lib.unique (
      builtins.concatMap (service: service.localAliases) (builtins.attrValues enabledServices)
    );

    assertions = lib.optionals (enabledServices != { }) [
      {
        assertion =
          (builtins.length enabledServerNames) == (builtins.length (lib.unique enabledServerNames));
        message = "host.internalHttps.services must not reuse the same serverName on one host.";
      }
    ];

    sops.secrets =
      lib.mapAttrs' (
        serviceName: service:
        lib.nameValuePair "${secretAttrName serviceName}-server-crt" {
          key = "${service.secretPrefix}/server_crt_unencrypted";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        }
      ) enabledServices
      // lib.mapAttrs' (
        serviceName: service:
        lib.nameValuePair "${secretAttrName serviceName}-server-key" {
          key = "${service.secretPrefix}/server_key";
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        }
      ) enabledServices
      // lib.mapAttrs' (
        clientName: client:
        lib.nameValuePair "${mtlsClientSecretAttrName clientName}-crt" {
          key = "${client.secretPrefix}/client_crt_unencrypted";
          owner = client.owner;
          group = client.group;
          mode = client.mode;
          restartUnits = client.restartUnits;
        }
      ) enabledMtlsClients
      // lib.mapAttrs' (
        clientName: client:
        lib.nameValuePair "${mtlsClientSecretAttrName clientName}-key" {
          key = "${client.secretPrefix}/client_key";
          owner = client.owner;
          group = client.group;
          mode = client.mode;
          restartUnits = client.restartUnits;
        }
      ) enabledMtlsClients;

    services.nginx = lib.mkIf (enabledServices != { }) {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = lib.mapAttrs' (
        serviceName: service:
        lib.nameValuePair "internal-https-${serviceName}" {
          serverName = service.serverName;
          serverAliases = service.serverAliases;
          forceSSL = true;
          extraConfig = lib.optionalString service.mtls.enable ''
            ssl_client_certificate ${service.mtls.trustedCaCertificate};
            ssl_verify_client on;
          '';
          listen = [
            {
              addr = service.listenAddress;
              port = service.port;
              ssl = true;
            }
          ];
          sslCertificate = config.sops.secrets."${secretAttrName serviceName}-server-crt".path;
          sslCertificateKey = config.sops.secrets."${secretAttrName serviceName}-server-key".path;
          sslTrustedCertificate = internalPkiRootCaPath;
          locations.${service.path} = {
            proxyPass = service.upstream;
            proxyWebsockets = service.proxyWebsockets;
            recommendedProxySettings = service.recommendedProxySettings;
            extraConfig = service.locationExtraConfig;
          };
        }
      ) enabledServices;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf (enabledServices != { }) (
      lib.unique (
        builtins.concatMap (
          service:
          lib.optionals service.openFirewall [
            80
            service.port
          ]
        ) (builtins.attrValues enabledServices)
      )
    );

    systemd.services.nginx = lib.mkIf (enabledServices != { }) {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
