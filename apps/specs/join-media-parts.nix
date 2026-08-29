{
  fleetInventory,
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit fleetInventory outputs pkgs; }).packages.join-media-parts;
  description = "Join ordered TS/MP4/MKV/AVI media parts into one file.";
}
