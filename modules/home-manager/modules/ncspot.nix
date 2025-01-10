{ pkgs, ... }: with pkgs; writeScriptBin "spot" ''
  session_name=spot
  tmux=${tmux}/bin/tmux
  $tmux -2 new-session -s $session_name ${ncspot}/bin/ncspot || $tmux attach-session -t $session_name
''

