{ pkgs }:
{
  attention-inbox = pkgs.callPackage ./attention-inbox { };

  gh-restart-failed-jobs = pkgs.callPackage ./gh-restart-failed-jobs { };

  nr = pkgs.callPackage ./nr { };

  sync-repo = pkgs.callPackage ./sync-repo { };
}
