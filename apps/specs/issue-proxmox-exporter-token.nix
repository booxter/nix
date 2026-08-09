{ facts, pkgs, ... }:
{
  package = (import ../fleet.nix { inherit facts pkgs; }).packages.issue-proxmox-exporter-token;
  description = "Issue the Proxmox VE prometheus-pve-exporter API token and store it in host sops secrets.";
}
