{ lib, pkgs, ... }: {
  home.stateVersion = "24.05";
  programs.home-manager.enable = true; # let it manage itself

  # url: 127.0.0.1:8384
  services.syncthing.enable = true;
  services.git-sync.enable = true;

  programs.firefox = import ./programs/firefox.nix { inherit pkgs; inherit lib; };
  programs.thunderbird = import ./programs/thunderbird.nix { inherit pkgs; };
  programs.ssh = import ./programs/ssh.nix;
  programs.zsh = import ./programs/zsh.nix { inherit pkgs; };
  programs.emacs = import ./programs/emacs.nix { inherit pkgs; };
  programs.nixvim = import ./programs/nixvim.nix { inherit pkgs; };
  programs.tmux = import ./programs/tmux.nix { inherit pkgs; };
  programs.git = import ./programs/git.nix { inherit pkgs; };
  programs.gh = {
    enable = true;
    extensions = with pkgs; [ gh-dash gh-poi ];
  };
  programs.jq.enable = true;
  programs.less.enable = true;
  programs.sioyek.enable = true;
  programs.password-store.enable = true;

  # TODO: explore more features later
  programs.ranger = {
    enable = true;
    extraPackages = with pkgs; [
      w3m
    ];

    settings = {
      preview_images = true;
      preview_images_method = "kitty";
      preview_files = true;
      preview_directories = true;
      collapse_preview = true;

      # TODO: do I need a preview script like:
      # https://github.com/redxtech/nixfiles/blob/a9eba0db5c44c519eec8c837f6508cea8437bef7/modules/home-manager/cli/ranger/scope.sh ?
    };
  };

  # Sync notes and pass db
  services.git-sync = {
    repositories = {
      # TODO: pass username as argument
      password-store = {
        uri = "git+ssh://booxter@github.com:booxter/pass.git";
        path = "/Users/ihrachys/.local/share/password-store";
      };
      notes = {
        uri = "git+ssh://booxter@github.com:booxter/notes.git";
        path = "/Users/ihrachys/notes";
        interval = 30;
      };
    };
  };
  home.activation = {
    notes = import ./modules/git-sync-repo.nix {
      inherit pkgs; inherit lib;
      gh-repo = "booxter/notes";
      destdir = "~/notes";
    };
    pass = import ./modules/git-sync-repo.nix {
      inherit pkgs; inherit lib;
      gh-repo = "booxter/pass";
      destdir = "~/.local/share/password-store";
    };
  };

  home.packages = with pkgs; [
    ack
    chatgpt-cli
    curl
    file
    fzf
    git-pw
    git-review
    gnugrep
    gnupg
    gzip
    htop
    ipcalc
    iterm2
    jq
    less
    lima
    neofetch
    ngrep
    nix-tree
    obsidian
    page
    podman
    procps
    pstree
    python312Packages.ipython
    raycast
    ripgrep
    shell-gpt
    slack
    spotify
    tcpdump
    telegram-desktop
    tig
    tree
    unzip
    watch
    wireshark
    zip
    (import ./modules/devnest.nix { inherit pkgs; })
    (import ./modules/homerow.nix { inherit pkgs; inherit lib; })
    (import ./modules/vpn.nix { inherit pkgs; })
  ];

  # Use homebrew ssh for git. It supports gss.
  home.sessionVariables = {
    GIT_SSH_COMMAND = "ssh";
    BROWSER = "firefox";
    PAGER = "page -WO -q 90000";
    MANPAGER = "page -t man";
    HOMEBREW_NO_AUTO_UPDATE = 1;
  };
  home.sessionPath = [
    "$HOME/.config/emacs/bin"
  ];

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    # starship preset gruvbox-rainbow > ./modules/home-manager/config/starship.toml
    settings = (with builtins; fromTOML (readFile ./config/starship.toml));
  };

  targets.darwin.defaults."com.apple.Safari" = {
    AutoFillCreditCardData = true;
    AutoFillPasswords = true;
    IncludeDevelopMenu = true;
    ShowOverlayStatusBar = true;
  };

  programs.browserpass = {
    enable = true;
    browsers = [ "firefox" ];
  };

  accounts.email.accounts = import ./config/email.nix;
  programs.irssi = {
    enable = true;
    networks = import ./config/irc.nix;
  };

  home.file.".tigrc".source = pkgs.fetchFromGitHub {
      owner = "jonas";
      repo = "tig";
      rev = "c6899e98e10da37e8034e0f0cfd0904091ad34e5";
      sha256 = "sha256-crgIhsXqp6XpyF0vXYJIPpWmfLSCyeXCirWlrRxx/gg=";
  } + "/contrib/vim.tigrc";

  programs.kitty = import ./programs/kitty.nix;
  home.file.".config/kitty/open-actions.conf".source = ./dotfiles/kitty-open-actions.conf;

  # TODO: use native readline module for inputrc
  home.file.".inputrc".source = ./dotfiles/inputrc;
  home.file.".config/svim/blacklist".source = ./dotfiles/svim-blacklist;
  home.file.".iterm2/com.googlecode.iterm2.plist".source = ./dotfiles/iterm2.plist;
  home.file.".amethyst.yml".source = ./dotfiles/amethyst.yml;
  home.file."Library/Application Support/Telegram Desktop/tdata/shortcuts-custom.json".source = ./dotfiles/telegram-desktop-shortcuts.json;
  home.file.".bin/terminal-new-window.sh" = import ./modules/terminal-new-window.nix { inherit pkgs; };
}
