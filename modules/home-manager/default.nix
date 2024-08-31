{ lib, pkgs, username, ... }: {
  home.stateVersion = "24.05";
  programs.home-manager.enable = true; # let it manage itself

  # url: 127.0.0.1:8384
  services.syncthing.enable = true;
  services.git-sync.enable = true;

  programs.firefox = import ./programs/firefox.nix { inherit pkgs lib; };
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
  programs.eza = import ./programs/eza.nix;
  programs.jq.enable = true;
  programs.less.enable = true;
  programs.sioyek.enable = true;
  programs.password-store.enable = true;
  programs.bat.enable = true;

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
      password-store = {
        uri = "git+ssh://booxter@github.com:booxter/pass.git";
        path = "/Users/${username}/.local/share/password-store";
      };
      notes = {
        uri = "git+ssh://booxter@github.com:booxter/notes.git";
        path = "/Users/${username}/notes";
        interval = 30;
      };
      weechat-config = {
        uri = "git+ssh://booxter@github.com:booxter/weechat-config.git";
        path = "/Users/${username}/.config/weechat";
      };
    };
  };
  home.activation = {
    notes = import ./modules/git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/notes";
      destdir = "~/notes";
    };
    pass = import ./modules/git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/pass";
      destdir = "~/.local/share/password-store";
    };
    weechat-config = import ./modules/git-sync-repo.nix {
      inherit pkgs lib;
      gh-repo = "booxter/weechat-config";
      destdir = "~/.config/weechat";
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
    jq
    less
    lima
    magic-wormhole
    neofetch
    ngrep
    nix-tree
    obsidian
    page
    podman
    procps
    pstree
    python312Packages.ipython
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
    weechat
    wireshark
    zip
    (import ./modules/devnest.nix { inherit pkgs; })
  ]
  ++ lib.optionals stdenv.isDarwin [
    iterm2
    raycast
    (import ./modules/homerow.nix { inherit pkgs lib; })
    (import ./modules/vpn.nix { inherit pkgs; })
  ];

  home.sessionVariables = {
    # Use homebrew ssh for git. It supports gss.
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

  programs.browserpass = {
    enable = true;
    browsers = [ "firefox" ];
  };

  accounts.email.accounts = import ./config/email.nix;
  programs.irssi = {
    enable = true;
    networks = import ./config/irc.nix;
  };

  programs.kitty = import ./programs/kitty.nix;

  # TODO: move darwin specific config files to a separate module?
  home.file = {
    # TODO: use native readline module for inputrc
    ".inputrc".source = ./dotfiles/inputrc;

    ".config/kitty/open-actions.conf".source = ./dotfiles/kitty-open-actions.conf;

    ".tigrc".source = pkgs.fetchFromGitHub {
      owner = "jonas";
      repo = "tig";
      rev = "c6899e98e10da37e8034e0f0cfd0904091ad34e5";
      sha256 = "sha256-crgIhsXqp6XpyF0vXYJIPpWmfLSCyeXCirWlrRxx/gg=";
    } + "/contrib/vim.tigrc";
  } // lib.optionalAttrs pkgs.stdenv.isDarwin {
    ".config/svim/blacklist".source = ./dotfiles/svim-blacklist;
    ".iterm2/com.googlecode.iterm2.plist".source = ./dotfiles/iterm2.plist;
    ".amethyst.yml".source = ./dotfiles/amethyst.yml;
    # TODO: configure telegram for other platforms too (use conditional paths?)
    "Library/Application Support/Telegram Desktop/tdata/shortcuts-custom.json".source = ./dotfiles/telegram-desktop-shortcuts.json;
    ".bin/terminal-new-window.sh" = import ./modules/terminal-new-window.nix { inherit pkgs; };
  };
}
