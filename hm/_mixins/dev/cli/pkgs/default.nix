{ pkgs }:
{
  gh-restart-failed-jobs = pkgs.callPackage ./gh-restart-failed-jobs { };
}
