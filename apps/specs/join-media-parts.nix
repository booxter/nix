{
  outputs,
  pkgs,
  ...
}:
{
  package = (import ../fleet.nix { inherit outputs pkgs; }).packages.join-media-parts;
  description = "Join ordered TS/MP4/MKV media parts into one file.";
}
