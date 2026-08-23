{
  config,
  lib,
  proxmoxTopology,
  ...
}:
let
  cfg = config.host.proxmox;
  url = "https://${cfg.node.apiServerName}/";
in
{
  config = lib.mkIf (cfg.node != null && proxmoxTopology.isController) {
    host.dashboard.entries."proxmox-${proxmoxTopology.clusterName}" = {
      title = "Proxmox VE";
      icon = "sh:proxmox";
      section = "infrastructure";
      inherit url;
    };
  };
}
