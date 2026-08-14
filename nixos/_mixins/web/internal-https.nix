{
  config,
  lib,
  webModel,
  ...
}:
let
  services = webModel.normalizedInternalServices;
  endpoints = webModel.internalEndpoints;
  endpointNames = webModel.internalEndpointNames;
  serverNames = builtins.concatMap (
    service:
    [ service.internal.serverName ] ++ service.internal.serverAliases ++ service.internal.publicAliases
  ) (builtins.attrValues services);
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  secretName = endpointName: "internal-https-${endpointName}";
  nginxSecret = key: {
    inherit key;
    owner = config.services.nginx.user;
    group = config.services.nginx.group;
    mode = "0400";
    restartUnits = [ "nginx.service" ];
  };
  healthProbeEndpointNames = map (service: service.internal.endpointName) (
    builtins.attrValues (lib.filterAttrs (_: service: service.health.backend.enable) services)
  );
  apiProbeEndpointNames = map (api: services.${api.service}.internal.endpointName) (
    builtins.attrValues (
      lib.filterAttrs (_: api: builtins.hasAttr api.service services) config.host.web.api
    )
  );
  gateProbeEndpointNames = lib.unique (
    builtins.concatMap (gate: builtins.attrNames gate.probeLocationsByName) (
      builtins.attrValues (lib.filterAttrs (_: gate: gate.enable) config.host.sso.oauth2ProxyGates)
    )
  );
  probeEndpointNames = lib.unique (
    healthProbeEndpointNames ++ apiProbeEndpointNames ++ gateProbeEndpointNames
  );
  probeServices = lib.genAttrs probeEndpointNames (name: endpoints.${name});
  probePortConflicts = lib.filterAttrs (
    _: service: service.health.backend.port == service.internal.port
  ) probeServices;
  firewallPortsFor =
    service:
    lib.optionals service.internal.openFirewall [
      80
      service.internal.port
    ];
  tlsVhost = service: port: {
    extraConfig = lib.optionalString (service.internal.clientAuth == "mtls") ''
      ssl_client_certificate ${pkiRootCaPath};
      ssl_verify_client on;
    '';
    listen = [
      {
        addr = service.internal.listenAddress;
        inherit port;
        ssl = true;
      }
    ];
    sslCertificate = config.sops.secrets."${secretName service.internal.endpointName}-server-crt".path;
    sslCertificateKey =
      config.sops.secrets."${secretName service.internal.endpointName}-server-key".path;
    sslTrustedCertificate = pkiRootCaPath;
  };
  proxyVhost =
    service: serverName: serverAliases:
    (tlsVhost service service.internal.port)
    // {
      inherit serverName serverAliases;
      forceSSL = true;
      locations.${service.internal.path} = {
        proxyPass = service.upstream;
        inherit (service.internal)
          proxyWebsockets
          recommendedProxySettings
          ;
        extraConfig = service.internal.locationExtraConfig;
      };
    };
  serviceVhosts = lib.mapAttrs' (
    _: service:
    lib.nameValuePair (secretName service.internal.endpointName) (
      proxyVhost service service.internal.serverName service.internal.serverAliases
    )
  ) services;
  publicVhosts = lib.concatMapAttrs (
    _: service:
    lib.genAttrs service.internal.publicAliases (publicAlias: proxyVhost service publicAlias [ ])
  ) services;
  probeVhosts = lib.mapAttrs' (
    _: service:
    lib.nameValuePair "${secretName service.internal.endpointName}-probe" (
      (tlsVhost service service.health.backend.port)
      // {
        serverName = service.internal.serverName;
        serverAliases = [ ];
        addSSL = true;
        forceSSL = false;
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
  config = lib.mkIf (services != { }) {
    assertions = [
      {
        assertion = builtins.length endpointNames == builtins.length (lib.unique endpointNames);
        message = "host.web.services must use unique internal endpoint names on one host";
      }
      {
        assertion = builtins.length serverNames == builtins.length (lib.unique serverNames);
        message = "host.web.services must not reuse internal server names or aliases on one host";
      }
      {
        assertion = probePortConflicts == { };
        message = "Internal web probe listeners must use a port distinct from the normal service port. Offenders: ${lib.concatStringsSep ", " (builtins.attrNames probePortConflicts)}";
      }
    ];

    host.pki.certificates = lib.mapAttrs' (
      _: service:
      lib.nameValuePair "internal_https_server/${service.internal.endpointName}" {
        category = "internal_https_server";
        name = service.internal.endpointName;
        commonName = service.internal.serverName;
        inherit (service.internal)
          port
          sans
          secretPrefix
          ;
      }
    ) services;

    sops.secrets = lib.concatMapAttrs (
      _: service:
      let
        name = secretName service.internal.endpointName;
      in
      {
        "${name}-server-crt" = nginxSecret "${service.internal.secretPrefix}/server_crt_unencrypted";
        "${name}-server-key" = nginxSecret "${service.internal.secretPrefix}/server_key";
      }
    ) services;

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

    networking.firewall.allowedTCPPorts = lib.unique (
      builtins.concatMap firewallPortsFor (builtins.attrValues services)
      ++ builtins.concatMap (
        service: lib.optional service.internal.openFirewall service.health.backend.port
      ) (builtins.attrValues probeServices)
    );
  };
}
