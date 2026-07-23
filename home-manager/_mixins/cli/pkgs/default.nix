{ pkgs }:
{
  attention-inbox = pkgs.callPackage ./attention-inbox { };

  gh-restart-failed-jobs = pkgs.callPackage ./gh-restart-failed-jobs { };

  nr = pkgs.callPackage ./nr { };

  sync-repo = pkgs.callPackage ./sync-repo { };

  xrun-nixpkgs = pkgs.writeShellApplication {
    name = "xrun-nixpkgs";
    runtimeInputs = [ pkgs.openssh ];
    text = builtins.readFile ./xrun-nixpkgs.sh;

    meta = {
      description = "Build a Linux nixpkgs package remotely and run it through SSH X11 forwarding";
      license = pkgs.lib.licenses.mit;
      maintainers = with pkgs.lib.maintainers; [ booxter ];
      mainProgram = "xrun-nixpkgs";
    };
  };
}
