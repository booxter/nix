{ pkgs, ... }: {
  home.stateVersion = "24.05";
  programs.home-manager.enable = true; # let it manage itself

  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;
    userEmail = "ihar.hrachyshka@gmail.com";
    userName = "Ihar Hrachyshka";
    ignores = [
      "*.swp"
    ];

    extraConfig = {
      pw = {
	server = "https://patchwork.ozlabs.org/api/1.2";
	project = "ovn";
      };
      sendemail = {
	confirm = "auto";
	smtpServer = "smtp.gmail.com";
	smtpServerPort = 587;
	smtpEncryption = "tls";
	smtpUser = "ihrachys@redhat.com";
      };
      rerere.enabled = true;
      branch.sort = "-committerdate";
    };

    diff-so-fancy.enable = true;
    diff-so-fancy.markEmptyLines = false;
  };
  programs.gh.enable = true;

  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    historyLimit = 100000;
    baseIndex = 1;
    clock24 = true;
    keyMode = "vi";
    mouse = true;
    newSession = true; # create session if not running
    sensibleOnTop = true;
    plugins = [
      pkgs.tmuxPlugins.vim-tmux-navigator
    ];
    extraConfig = ''
      # Open panes in the same directory as the current pane
      bind '"' split-window -v -c "#{pane_current_path}"
      bind % split-window -h -c "#{pane_current_path}"
      bind c new-window -c "#{pane_current_path}"

      set -g window-style 'fg=colour247,bg=colour236'
      set -g window-active-style 'fg=default,bg=colour234'
    '';
  };

  home.packages = with pkgs; [
    git-pw
    python312Packages.ipython
    raycast
    telegram-desktop
    tig
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
