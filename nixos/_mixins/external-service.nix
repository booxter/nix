{ config, lib, ... }:
let
  cfg = config.host.externalService;
  hasPublicVhosts = cfg.virtualHosts != { };
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  enabledMtlsClients = lib.filterAttrs (
    _: client: client.enable && client.category == "internal"
  ) config.host.internalPki.clients;
  enabledUpstreamTlsVhosts = lib.filterAttrs (_: vhost: vhost.upstreamTls.enable) cfg.virtualHosts;
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
      proxyPass =
        if vhost.upstreamTls.enable then
          "http://127.0.0.1:${toString vhost.upstreamTls.localPort}"
        else
          vhost.proxyPass;
      proxyWebsockets = vhost.proxyWebsockets;
      recommendedProxySettings = false;
      extraConfig =
        recommendedProxyHeaders (if vhost.upstreamTls.enable then vhost.upstreamTls.serverName else "$host")
        + lib.optionalString vhost.upstreamTls.enable ''
          # Backends may emit their internal canonical URL in absolute redirects.
          proxy_redirect https://${vhost.upstreamTls.serverName}/ $scheme://$host/;
          proxy_redirect http://${vhost.upstreamTls.serverName}/ $scheme://$host/;
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
                description = "Name of the internal-category host.internalPki.clients entry used for the upstream connection.";
              };

              serverName = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = "TLS server name used for upstream SNI and certificate verification.";
              };

              localPort = lib.mkOption {
                type = with lib.types; nullOr port;
                default = null;
                description = "Loopback port on this host where the local mTLS tunnel listens.";
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
                assertion = vhost.upstreamTls.localPort != null;
                message = "host.externalService.virtualHosts.${hostName}.upstreamTls.localPort must be set when upstream mTLS is enabled.";
              }
              {
                assertion = builtins.hasAttr vhost.upstreamTls.clientName enabledMtlsClients;
                message = "host.externalService.virtualHosts.${hostName}.upstreamTls.clientName must reference an enabled internal-category host.internalPki.clients entry.";
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
      assertions = [
        {
          assertion =
            let
              ports = builtins.map (vhost: vhost.upstreamTls.localPort) (
                builtins.attrValues enabledUpstreamTlsVhosts
              );
            in
            (builtins.length ports) == (builtins.length (lib.unique ports));
          message = "host.externalService upstream mTLS tunnels must use unique local ports.";
        }
      ];

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

      services.stunnel = lib.mkIf (enabledUpstreamTlsVhosts != { }) {
        enable = true;
        # Reverse-proxy mTLS tunnels are chatty at stunnel's upstream "info"
        # default, logging each accepted connection and TLS session detail.
        logLevel = lib.mkDefault "warning";
        user = null;
        group = null;
        clients = lib.mapAttrs (_: vhost: {
          accept = "127.0.0.1:${toString vhost.upstreamTls.localPort}";
          connect = "${vhost.upstreamTls.serverName}:443";
          cert =
            config.sops.secrets.${
              enabledMtlsClients.${vhost.upstreamTls.clientName}.materializations.default.certificateSecretName
            }.path;
          key =
            config.sops.secrets.${
              enabledMtlsClients.${vhost.upstreamTls.clientName}.materializations.default.keySecretName
            }.path;
          checkHost = vhost.upstreamTls.serverName;
          sni = vhost.upstreamTls.serverName;
          CAFile = toString vhost.upstreamTls.trustedCaCertificate;
          verifyChain = true;
          OCSPaia = false;
        }) enabledUpstreamTlsVhosts;
      };

      systemd.services.stunnel = lib.mkIf (enabledUpstreamTlsVhosts != { }) {
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
