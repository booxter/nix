{ config, lib, ... }:
let
  cfg = config.host.externalService;
  hasPublicVhosts = cfg.virtualHosts != { };
  pkiRootCaPath = config.host.pki.rootCaCertificate;
  enabledMtlsClients = lib.filterAttrs (
    _: client: client.enable && client.category == "internal"
  ) config.host.pki.clients;
  enabledUpstreamTlsVhosts = lib.filterAttrs (_: vhost: vhost.upstreamTls.enable) cfg.virtualHosts;
  nginxMtlsClientNames = lib.unique (
    lib.filter (clientName: clientName != "") (
      map (vhost: vhost.upstreamTls.clientName) (builtins.attrValues enabledUpstreamTlsVhosts)
    )
  );
  recommendedProxyHeaders = hostHeader: ''
    proxy_set_header Host ${hostHeader};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
  mkPublicVhost = vhost: {
    forceSSL = vhost.forceSSL;
    enableACME = vhost.enableACME;
    locations."/" = {
      proxyPass = vhost.proxyPass;
      proxyWebsockets = vhost.proxyWebsockets;
      recommendedProxySettings = false;
      extraConfig =
        recommendedProxyHeaders (if vhost.upstreamTls.enable then vhost.upstreamTls.serverName else "$host")
        + lib.optionalString vhost.upstreamTls.enable ''
          proxy_ssl_certificate ${
            config.sops.secrets.${
              enabledMtlsClients.${vhost.upstreamTls.clientName}.materializations.default.certificateSecretName
            }.path
          };
          proxy_ssl_certificate_key ${
            config.sops.secrets.${
              enabledMtlsClients.${vhost.upstreamTls.clientName}.materializations.default.keySecretName
            }.path
          };
          proxy_ssl_trusted_certificate ${vhost.upstreamTls.trustedCaCertificate};
          proxy_ssl_verify on;
          proxy_ssl_server_name on;
          proxy_ssl_name ${vhost.upstreamTls.serverName};

          # Backends may emit their internal canonical URL in absolute redirects.
          proxy_redirect https://${vhost.upstreamTls.serverName}/ $scheme://$host/;
          proxy_redirect http://${vhost.upstreamTls.serverName}/ $scheme://$host/;
        ''
        + vhost.locationExtraConfig;
    };
  };
in
{
  imports = [ ./external-service/assertions.nix ];

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
                description = "Name of the internal-category host.pki.clients entry used for the upstream connection.";
              };

              serverName = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "TLS server name used for upstream SNI and certificate verification.";
              };

              trustedCaCertificate = lib.mkOption {
                type = lib.types.path;
                default = pkiRootCaPath;
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
      host.network.stableAddress.requiredBy = lib.optional hasPublicVhosts "public ingress";
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
      host.pki.clients = lib.genAttrs nginxMtlsClientNames (_: {
        materializations.default = {
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
          restartUnits = [ "nginx.service" ];
        };
      });

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

      systemd.services.nginx = lib.mkIf (enabledUpstreamTlsVhosts != { }) {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
      };

      networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall [
        80
        443
      ];
    })
  ];
}
