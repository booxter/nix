{ config, lib }:
let
  cfg = config.host.internalHttps;
  enabledServices = lib.filterAttrs (_: service: service.enable) cfg.services;
in
{
  inherit enabledServices;

  certificateServices = lib.filterAttrs (
    name: service:
    !(
      name == "proxmox"
      && config.host.proxmox.apiCertificate.enable
      && service.secretPrefix == config.host.proxmox.apiCertificate.secretPrefix
    )
  ) enabledServices;

  probeServices = lib.filterAttrs (_: service: service.probe.enable) enabledServices;
  secretName = serviceName: "internal-https-${serviceName}";
}
