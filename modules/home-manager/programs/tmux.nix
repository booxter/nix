{ pkgs, ... }: {
  enable = true;
  terminal = "tmux-256color";
  historyLimit = 100000;
  baseIndex = 1;
  clock24 = true;
  keyMode = "vi";
  mouse = true;
  newSession = true; # create session if not running
  sensibleOnTop = true;
  plugins = with pkgs.tmuxPlugins; [
    gruvbox
    jump
    logging
    tmux-fzf
    # -url implies fzf installed elsewhere - probably a bug in the package
    fzf-tmux-url
    vim-tmux-navigator
  ];
  extraConfig = ''
    # Open panes in the same directory as the current pane
    bind '"' split-window -v -c "#{pane_current_path}"
    bind % split-window -h -c "#{pane_current_path}"
    bind c new-window -c "#{pane_current_path}"

    set -g window-style 'fg=colour247,bg=colour236'
    set -g window-active-style 'fg=default,bg=colour234'

    bind-key -T copy-mode-vi v send-keys -X begin-selection
    bind-key -T copy-mode-vi y send-keys -X copy-selection-and-cancel
    bind-key -T copy-mode-vi p "paste-buffer; send-keys q"

    is_vim="ps -o state= -o comm= -t '#{pane_tty}' | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"
    is_fzf="ps -o state= -o comm= -t '#{pane_tty}' | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?fzf$'"
    bind -n C-h run "($is_vim && tmux send-keys C-h) || tmux select-pane -L"
    bind -n C-j run "($is_vim && tmux send-keys C-j)  || ($is_fzf && tmux send-keys C-j) || tmux select-pane -D"
    bind -n C-k run "($is_vim && tmux send-keys C-k) || ($is_fzf && tmux send-keys C-k)  || tmux select-pane -U"
    bind -n C-l run  "($is_vim && tmux send-keys C-l) || tmux select-pane -R"
    bind-key -n C-\\ if-shell "$is_vim" "send-keys C-\\" "select-pane -l"

    set -g @tmux-gruvbox 'light'
  '';
}
