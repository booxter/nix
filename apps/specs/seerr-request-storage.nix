{ facts, pkgs, ... }:
{
  package = (import ../fleet.nix { inherit facts pkgs; }).packages.seerr-request-storage;
  description = "Report storage consumed by Radarr and Sonarr files attributable to Seerr requests.";
}
