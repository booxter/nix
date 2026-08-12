{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    enabledServices
    probeServices
    secretName
    ;
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;

  tlsVhost = serviceName: service: port: {
    extraConfig = lib.optionalString service.mtls.enable ''
      ssl_client_certificate ${service.mtls.trustedCaCertificate};
      ssl_verify_client on;
    '';
    listen = [
      {
        addr = service.listenAddress;
        inherit port;
        ssl = true;
      }
    ];
    sslCertificate = config.sops.secrets."${secretName serviceName}-server-crt".path;
    sslCertificateKey = config.sops.secrets."${secretName serviceName}-server-key".path;
    sslTrustedCertificate = internalPkiRootCaPath;
  };

  proxyVhost =
    serviceName: service: serverName: serverAliases:
    (tlsVhost serviceName service service.port)
    // {
      inherit serverName serverAliases;
      forceSSL = true;
      locations.${service.path} = {
        proxyPass = service.upstream;
        proxyWebsockets = service.proxyWebsockets;
        recommendedProxySettings = service.recommendedProxySettings;
        extraConfig = service.locationExtraConfig;
      };
    };

  serviceVhosts = lib.mapAttrs' (
    serviceName: service:
    lib.nameValuePair (secretName serviceName) (
      proxyVhost serviceName service service.serverName service.serverAliases
    )
  ) enabledServices;

  publicVhosts = lib.concatMapAttrs (
    serviceName: service:
    lib.genAttrs service.publicAliases (publicAlias: proxyVhost serviceName service publicAlias [ ])
  ) enabledServices;

  probeVhosts = lib.mapAttrs' (
    serviceName: service:
    lib.nameValuePair "${secretName serviceName}-probe" (
      (tlsVhost serviceName service service.probe.port)
      // {
        serverName = service.serverName;
        serverAliases = [ ];
        addSSL = true;
        forceSSL = false;
        # Keep auth-bypass health endpoints off the normal listener used by
        # public ingress. Exact probe locations are contributed separately.
        locations."/" = {
          return = "404";
          extraConfig = ''
            auth_request off;
          '';
        };
      }
    )
  ) probeServices;
in
{
  config = lib.mkIf (enabledServices != { }) {
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts = serviceVhosts // publicVhosts // probeVhosts;
    };

    systemd.services.nginx = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
