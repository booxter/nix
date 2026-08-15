{ config, lib, ... }:
{
  assertions = builtins.concatLists (
    lib.mapAttrsToList (serviceName: service: [
      {
        assertion =
          service.public == null || service.internal == null || service.internal.clientAuth == "mtls";
        message = "host.web.services.${serviceName} public ingress requires an mTLS internal endpoint";
      }
    ]) config.host.web.services
  );
}
