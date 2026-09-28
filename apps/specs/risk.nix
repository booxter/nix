{ pkgs, ... }:
{
  package = pkgs.callPackage ../package-risk { };
  description = "Show vulnerability, maintainer, and version risks in configuration closures.";
}
