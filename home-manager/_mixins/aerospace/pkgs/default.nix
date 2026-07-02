{ pkgs }:
{
  aerospace-x11-aware-resize = pkgs.writeShellApplication {
    name = "aerospace-x11-aware-resize";
    runtimeInputs = with pkgs; [
      aerospace
      gawk
      wmctrl
      xprop
      xwininfo
    ];
    text = builtins.readFile ./aerospace-x11-aware-resize.sh;
  };
}
