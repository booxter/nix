{ pkgs, ... }:
{
  package = pkgs.flake-input-update-summary;
  description = "Generate a revision-linked flake input update summary.";
}
