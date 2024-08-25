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

    set -g @tmux-gruvbox 'light'
  '';
}
