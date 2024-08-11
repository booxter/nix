{ pkgs, ... }: {
  home.stateVersion = "24.05";
  programs.home-manager.enable = true; # let it manage itself

  programs.git.enable = true;
  programs.git.package = pkgs.gitAndTools.gitFull;
  programs.git.userEmail = "ihar.hrachyshka@gmail.com";
  programs.git.userName = "Ihar Hrachyshka";
  programs.gh.enable = true;

  programs.tmux.enable = true;
  programs.tmux.terminal = "tmux-256color";
  programs.tmux.historyLimit = 100000;

  home.packages = [
    pkgs.gitAndTools.gitFull
    pkgs.telegram-desktop
    pkgs.raycast
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    GIT_SSH_COMMAND = "ssh";
  };
  programs.neovim.enable = true;

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    autosuggestion.strategy = [ "match_prev_cmd" "completion" ];
    syntaxHighlighting.enable = true;
    initExtra = ''
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '';
    shellAliases = { ls = "ls --color=auto -F"; };
  };
  programs.starship.enable = true;
  programs.starship.enableZshIntegration = true;

  programs.alacritty = {
    enable = true;
    settings.font.normal.family = "MesloLGS Nerd Font Mono";
    settings.font.size = 16;
  };

  programs.ssh = {
    enable = true;
    forwardAgent = true;
    includes = [ "config.backup" ];
  };

  home.file.".inputrc".text = ''
    set show-all-if-ambiguous on
    set completion-ignore-case on
    set mark-directories on
    set mark-symlinked-directories on
    set match-hidden-files off
    set visible-stats on
    set keymap vi
    set editing-mode vi-insert
  '';
}
