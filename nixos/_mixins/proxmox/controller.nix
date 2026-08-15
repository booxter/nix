{ config, lib, ... }:
let
  cfg = config.host.proxmox;
  url = "https://${cfg.node.apiServerName}/";
in
{
  config = lib.mkIf (cfg.node != null && cfg.node.controller != null) {
    host.dashboard.entries."proxmox-${cfg.node.cluster}" = {
      title = "Proxmox VE";
      icon = "sh:proxmox";
      section = "infrastructure";
      inherit url;
    };
  };
}
