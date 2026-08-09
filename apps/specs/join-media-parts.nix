{ facts, pkgs, ... }:
{
  package = (import ../fleet.nix { inherit facts pkgs; }).packages.join-media-parts;
  description = "Join ordered TS/MP4/MKV media parts into one file.";
}
