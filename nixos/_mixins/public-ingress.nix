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
  ownedPublicServices = builtins.filter (
    service: service.owner == hostname && service.internalEndpointName != null
  ) hostInventory.publicServices;
  internalHttpsExports = builtins.listToAttrs (
    map
      (service: {
        name = service.id;
        value = {
          inherit (service) publicHost;
          backend = {
            type = "internal-https";
            serverName = config.host.internalHttps.services.${service.id}.serverName;
          };
        };
      })
      (
        builtins.filter (
          service:
          builtins.hasAttr service.id config.host.internalHttps.services
          && config.host.internalHttps.services.${service.id}.enable
        ) ownedPublicServices
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
        owner = hostName;
      };
    }) outputs.nixosConfigurations.${hostName}.config.host.publicIngress.exports
  ) realmHostNames;
  contributionNames = map (contribution: contribution.name) contributions;
  services = builtins.listToAttrs contributions;
  expectedServiceNames = map (service: service.id) (
    builtins.filter (
      service: hostInventory.nixosHosts.${service.owner}.realm == config.host.realm
    ) hostInventory.publicServices
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

  config = {
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
    ];
  };
}
