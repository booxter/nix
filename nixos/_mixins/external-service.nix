{ config, lib, ... }:
let
  cfg = config.host.externalService;
  hasPublicVhosts = cfg.virtualHosts != { };
  internalPkiRootCaPath = ../../common/_mixins/internal-pki/home-internal-pki-root-ca.crt;
  enabledMtlsClients = lib.filterAttrs (_: client: client.enable) cfg.mtlsClients;
  mtlsClientSecretAttrName = clientName: "external-service-mtls-${clientName}";
  mkPublicVhost = vhost: {
    forceSSL = vhost.forceSSL;
    enableACME = vhost.enableACME;
    locations."/" = {
      proxyPass = vhost.proxyPass;
      proxyWebsockets = vhost.proxyWebsockets;
      extraConfig =
        lib.optionalString vhost.upstreamTls.enable ''
          proxy_ssl_server_name on;
          proxy_ssl_name ${vhost.upstreamTls.serverName};
          proxy_ssl_verify on;
          proxy_ssl_verify_depth 2;
          proxy_ssl_trusted_certificate ${vhost.upstreamTls.trustedCaCertificate};
          proxy_ssl_certificate ${
            config.sops.secrets."${mtlsClientSecretAttrName vhost.upstreamTls.clientName}-crt".path
          };
          proxy_ssl_certificate_key ${
            config.sops.secrets."${mtlsClientSecretAttrName vhost.upstreamTls.clientName}-key".path
          };
        ''
        + vhost.locationExtraConfig;
    };
  };
in
{
  options.host.externalService = {
    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "ihar.hrachyshka@gmail.com";
      description = "Email address used for ACME registrations for public ingress.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open TCP ports 80 and 443 for public ingress.";
    };

    ddns = {
      enable = lib.mkEnableOption "Dynu DDNS updates for public ingress";

      username = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Dynu username used by ddclient.";
      };

      hostname = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Dynu hostname updated by ddclient.";
      };

      passwordSopsKey = lib.mkOption {
        type = lib.types.str;
        default = "ddns/dynu/password";
        description = "SOPS key containing the Dynu password.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "3min";
        description = "ddclient update interval.";
      };
    };

    mtlsClients = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "internal PKI mTLS client identity";

              secretPrefix = lib.mkOption {
                type = lib.types.str;
                default = "internal_https/clients/${name}";
                description = "Secret prefix containing client_crt and client_key for this client identity.";
              };

              commonName = lib.mkOption {
                type = lib.types.str;
                default = "${name}.${config.host.dnsName}";
                description = "Leaf certificate common name to issue for this client identity.";
              };

              sans = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ ];
                description = "Optional SANs for this client certificate.";
              };
            };
          }
        )
      );
      default = { };
      description = "mTLS client identities used by public ingress when proxying to internal backends.";
    };

    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            proxyPass = lib.mkOption {
              type = lib.types.str;
              description = "Upstream URL for the public reverse proxy.";
            };

            forceSSL = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to redirect HTTP traffic to HTTPS.";
            };

            enableACME = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to provision certificates with ACME.";
            };

            proxyWebsockets = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to enable websocket proxy headers.";
            };

            locationExtraConfig = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Extra nginx location config appended after the generated proxy settings.";
            };

            upstreamTls = {
              enable = lib.mkEnableOption "mTLS-authenticated HTTPS to the upstream";

              clientName = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "Name of the host.externalService.mtlsClients entry used for the upstream connection.";
              };

              serverName = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "TLS server name used for upstream SNI and certificate verification.";
              };

              trustedCaCertificate = lib.mkOption {
                type = lib.types.path;
                default = internalPkiRootCaPath;
                description = "CA bundle used to verify the upstream TLS certificate.";
              };
            };
          };
        }
      );
      default = { };
      description = "Public nginx virtual hosts owned by this machine.";
    };
  };

  config = lib.mkMerge [
    {
      assertions =
        lib.optionals cfg.ddns.enable [
          {
            assertion = cfg.ddns.username != "";
            message = "host.externalService.ddns.username must be set when DDNS is enabled.";
          }
          {
            assertion = cfg.ddns.hostname != "";
            message = "host.externalService.ddns.hostname must be set when DDNS is enabled.";
          }
        ]
        ++ builtins.concatLists (
          lib.mapAttrsToList (
            hostName: vhost:
            lib.optionals vhost.upstreamTls.enable [
              {
                assertion = vhost.upstreamTls.clientName != "";
                message = "host.externalService.virtualHosts.${hostName}.upstreamTls.clientName must be set when upstream mTLS is enabled.";
              }
              {
                assertion = vhost.upstreamTls.serverName != "";
                message = "host.externalService.virtualHosts.${hostName}.upstreamTls.serverName must be set when upstream mTLS is enabled.";
              }
              {
                assertion = builtins.hasAttr vhost.upstreamTls.clientName enabledMtlsClients;
                message = "host.externalService.virtualHosts.${hostName}.upstreamTls.clientName must reference an enabled host.externalService.mtlsClients entry.";
              }
            ]
          ) cfg.virtualHosts
        );
    }

    (lib.mkIf cfg.ddns.enable {
      # Keep ddclient on a stable system user instead of DynamicUser. During
      # switch-to-configuration we observed transient startup failures where the
      # generated preStart script ran before the dynamic runtime state was ready.
      users.groups = {
        ddclient = { };
        ddclient-secrets = { };
      };
      users.users.ddclient = {
        isSystemUser = true;
        group = "ddclient";
      };

      sops = {
        useSystemdActivation = lib.mkDefault true;
        secrets.externalServiceDdnsPassword = {
          key = cfg.ddns.passwordSopsKey;
          group = "ddclient-secrets";
          mode = "0440";
        };
      };

      services.ddclient = {
        enable = true;
        interval = cfg.ddns.interval;
        protocol = "dyndns2";
        server = "api.dynu.com";
        username = cfg.ddns.username;
        passwordFile = config.sops.secrets.externalServiceDdnsPassword.path;
        domains = [ cfg.ddns.hostname ];
        ssl = true;
        quiet = true;
        usev4 = "webv4,webv4=checkip.dynu.com/,webv4-skip='IP Address'";
        usev6 = "";
      };

      systemd.services.ddclient = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "ddclient";
          Group = "ddclient";
          SupplementaryGroups = [ "ddclient-secrets" ];
        };
      };
    })

    (lib.mkIf hasPublicVhosts {
      sops.secrets =
        lib.mapAttrs' (
          clientName: client:
          lib.nameValuePair "${mtlsClientSecretAttrName clientName}-crt" {
            key = "${client.secretPrefix}/client_crt";
            owner = config.services.nginx.user;
            group = config.services.nginx.group;
            mode = "0400";
            restartUnits = [ "nginx.service" ];
          }
        ) enabledMtlsClients
        // lib.mapAttrs' (
          clientName: client:
          lib.nameValuePair "${mtlsClientSecretAttrName clientName}-key" {
            key = "${client.secretPrefix}/client_key";
            owner = config.services.nginx.user;
            group = config.services.nginx.group;
            mode = "0400";
            restartUnits = [ "nginx.service" ];
          }
        ) enabledMtlsClients;

      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.acmeEmail;
      };

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        virtualHosts = lib.mapAttrs (_: mkPublicVhost) cfg.virtualHosts;
      };

      networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [
        80
        443
      ];
    })
  ];
}
