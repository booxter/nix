{ config, lib, ... }:
let
  cfg = config.host.externalService;
  hasPublicVhosts = cfg.virtualHosts != { };
  mkPublicVhost = vhost: {
    forceSSL = vhost.forceSSL;
    enableACME = vhost.enableACME;
    locations."/" = {
      proxyPass = vhost.proxyPass;
      proxyWebsockets = vhost.proxyWebsockets;
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
        default = "1min";
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
          };
        }
      );
      default = { };
      description = "Public nginx virtual hosts owned by this machine.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.optionals cfg.ddns.enable [
        {
          assertion = cfg.ddns.username != "";
          message = "host.externalService.ddns.username must be set when DDNS is enabled.";
        }
        {
          assertion = cfg.ddns.hostname != "";
          message = "host.externalService.ddns.hostname must be set when DDNS is enabled.";
        }
      ];
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
