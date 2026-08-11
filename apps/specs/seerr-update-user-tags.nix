{
  facts,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit facts outputs pkgs; }).packages.seerr-update-user-tags;
  description = "Backfill Seerr requester tags onto existing Radarr and Sonarr items.";
}
