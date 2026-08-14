{ config, lib }:
let
  cfg = config.host.internalHttps;
  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;
in
{
  inherit enabledServices;

  certificateServices = enabledServices;

  probeServices = lib.filterAttrs (_: service: service.probe.enable) enabledServices;
  secretName = serviceName: "internal-https-${serviceName}";
}
