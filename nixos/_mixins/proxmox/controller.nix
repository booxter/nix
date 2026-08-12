{ config, lib, ... }:
let
  cfg = config.host.proxmox;
  api = cfg.apiCertificate;
  portSuffix = lib.optionalString (api.publicPort != 443) ":${toString api.publicPort}";
  url = "https://${api.serverName}${portSuffix}/";
in
{
  config = lib.mkIf cfg.controller.enable {
    host.dashboard.entries."proxmox-${cfg.cluster}" = {
      enable = true;
      title = "Proxmox VE";
      icon = "sh:proxmox";
      section = "infrastructure";
      endpoints.internal = {
        inherit url;
        checkUrl = url;
      };
    };
  };
}
