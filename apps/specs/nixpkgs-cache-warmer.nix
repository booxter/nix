{ pkgs, ... }:
{
  package = pkgs.callPackage ../nixpkgs-cache-warmer { };
  description = "Build maintained nixpkgs packages for the local store watcher.";
}
