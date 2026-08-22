{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package =
    (import ../fleet.nix { inherit fleetInventory outputs pkgs; })
    .packages.issue-proxmox-exporter-token;
  description = "Issue the Proxmox VE prometheus-pve-exporter API token and store it in host sops secrets.";
}
