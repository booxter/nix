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
  probeEndpointNames = lib.unique (healthProbeEndpointNames ++ apiProbeEndpointNames);
  probeServices = lib.genAttrs probeEndpointNames (name: endpoints.${name});
  tlsVhost = service: port: {
    extraConfig = lib.optionalString (service.internal.clientAuth == "mtls") ''
      ssl_client_certificate ${pkiRootCaPath};
      ssl_verify_client on;
    '';
    listen = [
      {
        addr = "0.0.0.0";
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
    (tlsVhost service 443)
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
  healthProbeLocation =
    service:
    let
      health = service.health.backend;
      proxyPass =
        if health.upstreamPath == null then
          service.upstream
        else
          "${service.upstream}${health.upstreamPath}";
      methodRestriction = lib.optionalString (health.allowedMethods != [ ]) ''
        limit_except ${lib.concatStringsSep " " health.allowedMethods} {
          deny all;
        }
      '';
    in
    {
      inherit proxyPass;
      inherit (health) recommendedProxySettings;
      extraConfig = ''
        auth_request off;
        ${methodRestriction}
        ${health.locationExtraConfig}
      '';
    };
  probeVhosts = lib.mapAttrs' (
    _: service:
    lib.nameValuePair "${secretName service.internal.endpointName}-probe" (
      (tlsVhost service 9443)
      // {
        serverName = service.internal.serverName;
        serverAliases = [ ];
        addSSL = true;
        forceSSL = false;
        locations = {
          "/" = {
            return = "404";
            extraConfig = ''
              auth_request off;
            '';
          };
        }
        // lib.optionalAttrs service.health.backend.enable {
          "= ${service.health.backend.path}" = healthProbeLocation service;
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
    ];

    host.pki.certificates = lib.mapAttrs' (
      _: service:
      lib.nameValuePair "internal_https_server/${service.internal.endpointName}" {
        commonName = service.internal.serverName;
        port = 443;
        inherit (service.internal) sans secretPrefix;
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

    networking.firewall.allowedTCPPorts = [
      80
      443
    ]
    ++ lib.optional (probeServices != { }) 9443;
  };
}
