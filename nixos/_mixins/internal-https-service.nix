{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.internalHttps;
  internalPkiRootCaPath = ../../common/_mixins/internal-pki/home-internal-pki-root-ca.crt;
  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;
  enabledServerNames = builtins.concatMap (service: [ service.serverName ] ++ service.serverAliases) (
    builtins.attrValues enabledServices
  );
  secretAttrName = serviceName: "internal-https-${serviceName}";
in
{
  options.host.internalHttps.services = lib.mkOption {
    type =
      with lib.types;
      attrsOf (
        submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "internal HTTPS service";

              serverName = lib.mkOption {
                type = str;
                default = "${name}.${hostInventory.site.lan.domain}";
                description = "DNS name presented by the internal HTTPS vhost.";
              };

              serverAliases = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ name ];
                description = "Additional hostnames served by the internal HTTPS vhost.";
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
                description = "SOPS key prefix containing server_crt and server_key for this service.";
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

  config = lib.mkIf (enabledServices != { }) {
    assertions = [
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
          key = "${service.secretPrefix}/server_crt";
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
      ) enabledServices;

    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = lib.mapAttrs' (
        serviceName: service:
        lib.nameValuePair "internal-https-${serviceName}" {
          serverName = service.serverName;
          serverAliases = service.serverAliases;
          onlySSL = true;
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

    networking.firewall.allowedTCPPorts = lib.unique (
      builtins.concatMap (service: lib.optional service.openFirewall service.port) (
        builtins.attrValues enabledServices
      )
    );

    systemd.services.nginx = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
