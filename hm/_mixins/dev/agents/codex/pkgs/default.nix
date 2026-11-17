{ pkgs }:
let
  sketchybarApplet =
    pkgs.python3Packages.callPackage ../../../../gui/sketchybar/pkgs/sketchybar-applet
      {
        inherit (pkgs) pythonRuffCheckHook;
      };
in
{
  codex-usage-status = pkgs.callPackage ./codex-tools { inherit sketchybarApplet; };
}
