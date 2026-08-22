{ pkgs, ... }:
{
  package = pkgs.callPackage ../nixpkgs-cache-warmer { };
  description = "Build maintained nixpkgs packages and publish them to Attic.";
}
