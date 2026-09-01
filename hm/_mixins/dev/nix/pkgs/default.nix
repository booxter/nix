{ pkgs }:
{
  nb = pkgs.callPackage ./nb { };
  nr = pkgs.callPackage ./nr { };
}
