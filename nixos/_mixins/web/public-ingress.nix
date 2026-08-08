{
  config,
  hostInventory,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.publicIngress;
  hostname = config.networking.hostName;
  realmPublicIngress = hostInventory.realms.${config.host.realm}.services.publicIngress or null;
  freeDns = hostInventory.site.dynamicDns.freeDns;

  localPublicServices = builtins.filter (
    service: hostInventory.serviceRunsOn hostname service && service.internalEndpointName != null
  ) hostInventory.publicServices;
  internalHttpsExports = builtins.listToAttrs (
    map
      (service: {
        name = service.id;
        value = {
          inherit (service) publicHost;
          backend = {
            type = "internal-https";
            serverName = config.host.internalService.services.${service.id}.serverName;
          };
        };
      })
      (
        builtins.filter (
          service:
          builtins.hasAttr service.id config.host.internalService.services
          && config.host.internalService.services.${service.id}.enable
        ) localPublicServices
      )
  );

  realmHostNames = map (spec: spec.name) (
    builtins.filter (spec: spec.realm == config.host.realm) hostInventory.nixosHostSpecs
  );
  contributions = lib.concatMap (
    hostName:
    lib.mapAttrsToList (serviceName: service: {
      name = serviceName;
      value = service // {
        host = hostName;
      };
    }) outputs.nixosConfigurations.${hostName}.config.host.publicIngress.exports
  ) realmHostNames;
  contributionNames = map (contribution: contribution.name) contributions;
  services = builtins.listToAttrs contributions;
  expectedServiceNames = map (service: service.id) (
    builtins.filter (
      service: hostInventory.nixosHosts.${hostInventory.serviceHost service}.realm == config.host.realm
    ) hostInventory.publicServices
  );

  internalHttpsServices = lib.filterAttrs (
    _: service: service.backend.type == "internal-https"
  ) cfg.services;
  internalHttpsServiceNames = builtins.attrNames internalHttpsServices;
  tunnelPorts = builtins.listToAttrs (
    lib.imap0 (index: serviceName: {
      name = serviceName;
      value = 18000 + index;
    }) internalHttpsServiceNames
  );
  mtlsBackends = lib.mapAttrs (serviceName: service: {
    clientName = serviceName;
    inherit (service.backend) serverName;
    localPort = tunnelPorts.${serviceName};
  }) internalHttpsServices;
  invalidInternalHttpsServices = lib.filterAttrs (
    _: service: service.backend.type == "internal-https" && service.backend.serverName == null
  ) cfg.services;
  invalidLocalHttpServices = lib.filterAttrs (
    _: service:
    service.backend.type == "local-http" && (service.host != hostname || service.backend.url == null)
  ) cfg.services;
  edgeAuthenticatedServices = lib.filterAttrs (_: service: service.edgeAuth != null) cfg.services;
  sessionRefreshServices = lib.filterAttrs (
    _: service: service.edgeAuth ? sessionRefresh
  ) edgeAuthenticatedServices;
  sessionRefreshServiceNames = builtins.attrNames sessionRefreshServices;
  redisPorts = builtins.listToAttrs (
    lib.imap0 (index: serviceName: {
      name = serviceName;
      value = 6379 + index;
    }) sessionRefreshServiceNames
  );
  redisNameFor = serviceName: "oauth2-proxy-${serviceName}";
  redisUnitFor = serviceName: "redis-${redisNameFor serviceName}.service";
  mkEdgeAuthGate =
    serviceName: service:
    removeAttrs service.edgeAuth [ "sessionRefresh" ]
    // {
      enable = true;
      whitelistDomains = [ service.publicHost ];
      externalHostNames = [ service.publicHost ];
    }
    // lib.optionalAttrs (service.edgeAuth ? sessionRefresh) {
      sessionRefresh = service.edgeAuth.sessionRefresh // {
        redisConnectionUrl = "redis://127.0.0.1:${toString redisPorts.${serviceName}}/0";
        redisServiceUnit = redisUnitFor serviceName;
      };
    };

  mkVirtualHost =
    serviceName: service:
    lib.nameValuePair service.publicHost (
      if service.backend.type == "internal-https" then
        let
          backend = mtlsBackends.${serviceName};
        in
        {
          proxyPass = "https://${backend.serverName}";
          inherit (service) locationExtraConfig;
          upstreamTls = {
            enable = true;
            inherit (backend)
              clientName
              localPort
              serverName
              ;
          };
        }
      else
        {
          proxyPass = service.backend.url;
          inherit (service) locationExtraConfig;
        }
    );
in
{
  options.host.publicIngress = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = realmPublicIngress != null && realmPublicIngress.host == hostname;
      readOnly = true;
      internal = true;
      description = "Whether this host provides public HTTPS ingress for its realm.";
    };

    exports = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            publicHost = lib.mkOption {
              type = lib.types.str;
              description = "Browser-facing hostname routed to this service.";
            };

            backend = {
              type = lib.mkOption {
                type = lib.types.enum [
                  "internal-https"
                  "local-http"
                ];
                description = "Transport used by the public ingress host.";
              };

              serverName = lib.mkOption {
                type = with lib.types; nullOr str;
                default = null;
                description = "Internal HTTPS server name used for authenticated upstream TLS.";
              };

              url = lib.mkOption {
                type = with lib.types; nullOr str;
                default = null;
                description = "Local HTTP upstream URL on the public ingress host.";
              };
            };

            locationExtraConfig = lib.mkOption {
              type = lib.types.lines;
              default = "";
              description = "Additional nginx configuration for the public proxy location.";
            };

            edgeAuth = lib.mkOption {
              type = with lib.types; nullOr (attrsOf anything);
              default = null;
              description = "OAuth2 Proxy gate requested from the public ingress host.";
            };
          };
        }
      );
      default = { };
      description = "Public service endpoints contributed by this host.";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      internal = true;
      description = "Public service exports collected from this realm.";
    };
  };

  config = lib.mkMerge [
    {
      host.publicIngress = {
        exports = internalHttpsExports;
        services = if cfg.enable then services else { };
      };

      assertions = lib.optionals cfg.enable [
        {
          assertion = builtins.length contributionNames == builtins.length (lib.unique contributionNames);
          message = "Public service IDs must be exported by exactly one host.";
        }
        {
          assertion = lib.subtractLists contributionNames expectedServiceNames == [ ];
          message = "Public services missing realm exports: ${lib.concatStringsSep ", " (lib.subtractLists contributionNames expectedServiceNames)}";
        }
        {
          assertion = lib.subtractLists expectedServiceNames contributionNames == [ ];
          message = "Unknown public service exports: ${lib.concatStringsSep ", " (lib.subtractLists expectedServiceNames contributionNames)}";
        }
        {
          assertion = invalidInternalHttpsServices == { };
          message = "Internal HTTPS ingress exports must declare a server name: ${lib.concatStringsSep ", " (builtins.attrNames invalidInternalHttpsServices)}";
        }
        {
          assertion = invalidLocalHttpServices == { };
          message = "Local HTTP ingress exports must belong to the ingress host and declare a URL: ${lib.concatStringsSep ", " (builtins.attrNames invalidLocalHttpServices)}";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      host.internalPki.clients = builtins.mapAttrs (_: _: {
        enable = true;
        category = "internal";
        materializations.default.restartUnits = [ "stunnel.service" ];
      }) mtlsBackends;

      host.externalService = {
        ddns = {
          enable = true;
          hostname = freeDns.records.${hostname};
          inherit (freeDns) username;
        };
        virtualHosts = lib.mapAttrs' mkVirtualHost cfg.services;
      };

      host.sso.oauth2ProxyGates = lib.mapAttrs mkEdgeAuthGate edgeAuthenticatedServices;

      services.redis.servers = lib.mapAttrs' (
        serviceName: _:
        lib.nameValuePair (redisNameFor serviceName) {
          enable = true;
          bind = "127.0.0.1";
          port = redisPorts.${serviceName};
          openFirewall = false;
          save = [ ];
          appendOnly = true;
          appendFsync = "everysec";
          settings = {
            maxmemory = "64mb";
            maxmemory-policy = "volatile-ttl";
          };
        }
      ) sessionRefreshServices;

      # Keep public ingress config-only changes from dropping long-lived
      # proxied streams.
      services.nginx.enableReload = true;
    })
  ];
}
