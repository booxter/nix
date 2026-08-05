{ pkgs }:
let
  gitCommandRunner = pkgs.python3Packages.callPackage ../../../../pkgs/git-command-runner { };
in
{
  attention-inbox = pkgs.callPackage ./attention-inbox { };

  git-command-runner = gitCommandRunner;

  gh-restart-failed-jobs = pkgs.callPackage ./gh-restart-failed-jobs { };

  nr = pkgs.callPackage ./nr { };

  sync-git-mains = pkgs.callPackage ./sync-git-mains { inherit gitCommandRunner; };

  sync-repo = pkgs.callPackage ./sync-repo { inherit gitCommandRunner; };
}
