{
  config,
  fleetWebServices,
  lib,
  ...
}:
let
  cfg = config.host.web.ingress;
  dynamicDnsPolicy = import ../../../../common/_lib/dynamic-dns-policy.nix { inherit lib; };
  publicServices = builtins.filter (
    contribution: contribution.value.public.ingressHost == config.networking.hostName
  ) fleetWebServices.public;
  mtlsPublicServices = builtins.filter (
    contribution: contribution.value.internal != null
  ) publicServices;
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  proxyHeaders = hostHeader: ''
    proxy_set_header Host ${hostHeader};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
  publicVhost =
    contribution:
    let
      service = contribution.value;
      mtls = service.internal != null;
      client = config.host.pki.clients.${contribution.id}.materializations.default;
    in
    {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = if mtls then service.internal.url else service.upstream;
        proxyWebsockets = true;
        recommendedProxySettings = false;
        extraConfig =
          proxyHeaders (if mtls then service.internal.serverName else "$host")
          + lib.optionalString mtls ''
            proxy_ssl_certificate ${client.certificatePath};
            proxy_ssl_certificate_key ${client.keyPath};
            proxy_ssl_trusted_certificate ${pkiRootCaPath};
            proxy_ssl_verify on;
            proxy_ssl_server_name on;
            proxy_ssl_name ${service.internal.serverName};

            # Backends may emit their internal canonical URL in absolute redirects.
            proxy_redirect https://${service.internal.serverName}/ $scheme://$host/;
            proxy_redirect http://${service.internal.serverName}/ $scheme://$host/;
          ''
          + service.public.locationExtraConfig;
      };
    };
in
{
  imports = [ ./bandwidth-limits.nix ];

  options.host.web.ingress = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options.dynamicDns = lib.mkOption {
          type = lib.types.nullOr dynamicDnsPolicy;
          default = null;
          description = "Dynamic DNS policy for this ingress controller.";
        };
      }
    );
    default = null;
    description = "Public HTTPS ingress controller policy.";
  };

  config = lib.mkIf (cfg != null) {
    host.network.stableAddress.requiredBy = lib.optional (publicServices != [ ]) "public ingress";

    host.pki.clients = builtins.listToAttrs (
      map (contribution: {
        name = contribution.id;
        value = {
          category = "internal";
          materializations.default = {
            owner = config.services.nginx.user;
            group = config.services.nginx.group;
            mode = "0400";
            restartUnits = [ "nginx.service" ];
          };
        };
      }) mtlsPublicServices
    );

    security.acme = lib.mkIf (publicServices != [ ]) {
      acceptTerms = true;
      defaults.email = "ihar.hrachyshka@gmail.com";
    };

    services.nginx = lib.mkMerge [
      { enableReload = true; }
      (lib.mkIf (publicServices != [ ]) {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        virtualHosts = builtins.listToAttrs (
          map (contribution: {
            name = contribution.value.public.hostName;
            value = publicVhost contribution;
          }) publicServices
        );
      })
    ];

    systemd.services.nginx = lib.mkIf (mtlsPublicServices != [ ]) {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };

    networking.firewall.allowedTCPPorts = lib.optionals (publicServices != [ ]) [
      80
      443
    ];
  };
}
