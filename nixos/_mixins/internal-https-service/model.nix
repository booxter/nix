{ config, lib }:
let
  cfg = config.host.internalHttps;
in
{
  services = cfg.services;
  probeServices = lib.filterAttrs (_: service: service.probe != null) cfg.services;
  secretName = serviceName: "internal-https-${serviceName}";
}
