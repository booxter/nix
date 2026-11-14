{ pkgs, ... }:
{
  package = pkgs.callPackage ../ci-build { };
  description = "Build CI targets and publish their output closures to the public cache.";
}
