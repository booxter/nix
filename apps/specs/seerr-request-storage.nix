{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package =
    (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.seerr-request-storage;
  description = "Report storage consumed by Radarr and Sonarr files attributable to Seerr requests.";
}
