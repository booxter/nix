{ pkgs, ... }: {
  home.stateVersion = "24.05";
  programs.home-manager.enable = true; # let it manage itself

  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;
    userEmail = "ihar.hrachyshka@gmail.com";
    userName = "Ihar Hrachyshka";
  };
  programs.gh.enable = true;

  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    historyLimit = 100000;
    keyMode = "vi";
    mouse = true;
    newSession = true; # create session if not running
    plugins = [
      pkgs.tmuxPlugins.vim-tmux-navigator
    ];
  };

  home.packages = with pkgs; [
    tig
    gitAndTools.gitFull
    telegram-desktop
    raycast
  ];

  # Use homebrew ssh for git. It supports gss.
  home.sessionVariables = {
    GIT_SSH_COMMAND = "ssh";
  };

  programs.nixvim = import ./nixvim.nix { inherit pkgs; }; 

  programs.zsh = {
    enable = true;
    autosuggestion = {
      enable = true;
      strategy = [ "match_prev_cmd" "completion" ];
    };
    syntaxHighlighting.enable = true;
    initExtra = ''
      eval "$(/opt/homebrew/bin/brew shellenv)"
    '';
    shellAliases = { ls = "ls --color=auto -F"; };
  };
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.alacritty = {
    enable = true;
    settings.font = {
      normal.family = "MesloLGS Nerd Font Mono";
      size = 16;
    };
  };

  programs.ssh = {
    enable = true;
    forwardAgent = true;
    includes = [ "config.backup" ];
  };

  home.file.".inputrc".source = ./dotfiles/inputrc;
}
