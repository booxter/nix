{ config, lib, ... }:
{
  assertions = builtins.concatLists (
    lib.mapAttrsToList (serviceName: service: [
      {
        assertion =
          service.public == null || service.public.transport != "internal-mtls" || service.internal != null;
        message = "host.web.services.${serviceName} public exposure requires internal HTTPS";
      }
      {
        assertion =
          service.public == null
          || service.public.transport != "internal-mtls"
          || service.internal.clientAuth == "mtls";
        message = "host.web.services.${serviceName} public ingress requires an mTLS internal endpoint";
      }
      {
        assertion =
          service.public == null
          || service.public.transport != "direct"
          || service.public.directUpstream != null;
        message = "host.web.services.${serviceName} direct public ingress requires directUpstream";
      }
      {
        assertion = !service.dashboard.enable || service.dashboard.section != null;
        message = "host.web.services.${serviceName} dashboard entries require a category";
      }
      {
        assertion = !service.observability.externalProbe.enable || service.public != null;
        message = "host.web.services.${serviceName} external probing requires public exposure";
      }
      {
        assertion = !service.observability.externalProbe.enable || service.health.frontend.enable;
        message = "host.web.services.${serviceName} external probing requires a frontend health probe";
      }
    ]) config.host.web.services
  );
}
