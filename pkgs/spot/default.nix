{ lib, pkgs, ... }: let
  session = "spot";
in pkgs.writeScriptBin "spot" ''
  ${lib.getExe pkgs.tmux} -2 new-session -s ${session} ${lib.getExe pkgs.spotify-player} || ${lib.getExe pkgs.tmux} attach-session -t ${session}
''

