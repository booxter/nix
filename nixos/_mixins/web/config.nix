{
  config,
  fleetInventory,
  lib,
  outputs,
  ...
}:
let
  services = config.host.web.services;
  localHost = config.networking.hostName;
  localInventoryEntries = fleetInventory.webServices.byOwner.${localHost} or { };
  inventoryServices = lib.mapAttrs (_: entry: entry.declaration) localInventoryEntries;
  inventoryServiceIds = builtins.attrNames localInventoryEntries;
  localServiceIds = builtins.attrNames services;
  internalServices = lib.filterAttrs (_: service: service.internal != null) services;
  metrics = lib.concatMapAttrs (
    serviceName: service:
    lib.mapAttrs' (
      _: metric:
      lib.nameValuePair metric.endpointName (
        metric
        // {
          inherit serviceName;
          serviceAvailability = service.observability.availability;
        }
      )
    ) service.metrics
  ) services;
in
{
  config = lib.mkMerge [
    {
      host.web.services = inventoryServices;

      assertions = [
        {
          assertion = localServiceIds == inventoryServiceIds;
          message =
            "host.web.services on ${localHost} must match its fleet inventory; "
            + "configured: ${lib.concatStringsSep ", " localServiceIds}; "
            + "inventoried: ${lib.concatStringsSep ", " inventoryServiceIds}";
        }
      ];

      _module.args.fleetWebServices = import ../../_lib/fleet-web-services.nix {
        inherit
          fleetInventory
          lib
          outputs
          ;
      };

      host.network.stableAddress.requiredBy = lib.optional (
        internalServices != { }
      ) "internal web service DNS";
    }

    (lib.mkIf (metrics != { }) {
      host.observability.prometheusEndpoints = lib.mapAttrs (_: metric: {
        inherit (metric)
          openFirewall
          path
          port
          upstream
          ;
        scrape =
          if metric.discover then
            {
              inherit (metric) jobName labels;
              profile = "application";
              component = metric.serviceName;
              service = metric.serviceName;
              availability = metric.serviceAvailability;
              interval = metric.scrapeInterval;
            }
          else
            null;
      }) metrics;
    })

  ];
}
