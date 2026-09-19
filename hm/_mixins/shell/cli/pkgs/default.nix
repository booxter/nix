{ pkgs }:
let
  gitCommandRunner = pkgs.python3Packages.callPackage ../../../../../pkgs/git-command-runner {
    inherit (pkgs) pythonRuffCheckHook;
  };
in
{
  git-command-runner = gitCommandRunner;

  sync-repo = pkgs.callPackage ./sync-repo { inherit gitCommandRunner; };
}
