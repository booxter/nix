{ config, lib, ... }:
let
  enabledServices = lib.filterAttrs (_: service: service.enable) config.host.web.services;
in
{
  assertions = builtins.concatLists (
    lib.mapAttrsToList (serviceName: service: [
      {
        assertion = !service.internal.enable || service.upstream != null;
        message = "host.web.services.${serviceName}.upstream is required for internal HTTPS exposure";
      }
      {
        assertion = !service.public.enable || service.public.hostName != null;
        message = "host.web.services.${serviceName}.public.hostName is required for public exposure";
      }
      {
        assertion =
          !service.public.enable || service.public.transport != "internal-mtls" || service.internal.enable;
        message = "host.web.services.${serviceName} public exposure requires internal HTTPS";
      }
      {
        assertion =
          !service.public.enable
          || service.public.transport != "internal-mtls"
          || service.internal.clientAuth == "mtls";
        message = "host.web.services.${serviceName} public ingress requires an mTLS internal endpoint";
      }
      {
        assertion =
          !service.public.enable
          || service.public.transport != "direct"
          || service.public.directUpstream != null;
        message = "host.web.services.${serviceName} direct public ingress requires directUpstream";
      }
      {
        assertion =
          !service.presentation.dashboard.enable || service.presentation.dashboard.category != null;
        message = "host.web.services.${serviceName} dashboard entries require a category";
      }
      {
        assertion = !service.observability.externalProbe.enable || service.public.enable;
        message = "host.web.services.${serviceName} external probing requires public exposure";
      }
      {
        assertion = !service.observability.externalProbe.enable || service.health.frontend.enable;
        message = "host.web.services.${serviceName} external probing requires a frontend health probe";
      }
    ]) enabledServices
  );
}
