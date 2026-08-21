{
  config,
  lib,
  outputs,
  ...
}:
let
  services = config.host.web.services;
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
  oidcServices = lib.filterAttrs (_: service: service.auth.oidcRegistration != null) services;
  oauth2ProxyServices = lib.filterAttrs (_: service: service.auth.oauth2ProxyGate != null) services;
in
{
  config = lib.mkMerge [
    {
      _module.args.fleetWebServices = import ../../_lib/fleet-web-services.nix {
        inherit config lib outputs;
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

    (lib.mkIf (oidcServices != { }) {
      host.sso.oidc.registrations = lib.mapAttrs' (
        serviceName: service: lib.nameValuePair serviceName service.auth.oidcRegistration
      ) oidcServices;
    })

    (lib.mkIf (oauth2ProxyServices != { }) {
      host.sso.oauth2ProxyGates = lib.mapAttrs' (
        serviceName: service: lib.nameValuePair serviceName service.auth.oauth2ProxyGate
      ) oauth2ProxyServices;
    })
  ];
}
