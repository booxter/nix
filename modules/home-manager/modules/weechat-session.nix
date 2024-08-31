{ pkgs, ... }: with pkgs; writeScriptBin "irc" ''
  session_name=irc
  tmux=${tmux}/bin/tmux
  $tmux -2 new-session -s $session_name ${weechat}/bin/weechat || $tmux attach-session -t $session_name
''

