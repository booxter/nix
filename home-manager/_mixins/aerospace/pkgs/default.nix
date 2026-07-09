{ pkgs }:
{
  aerospace-reap-ghosts = pkgs.writeShellApplication {
    name = "aerospace-reap-ghosts";
    runtimeInputs = with pkgs; [
      aerospace
      coreutils
      jq
    ];
    text = builtins.readFile ./aerospace-reap-ghosts.sh;
  };

  aerospace-x11-aware-move = pkgs.writeShellApplication {
    name = "aerospace-x11-aware-move";
    runtimeInputs = with pkgs; [
      aerospace
      gawk
      wmctrl
      xprop
      xwininfo
    ];
    text = builtins.readFile ./aerospace-x11-aware-move.sh;
  };

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
