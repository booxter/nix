{
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit outputs pkgs; }).packages.seerr-request-storage;
  description = "Report storage consumed by Radarr and Sonarr files attributable to Seerr requests.";
}
