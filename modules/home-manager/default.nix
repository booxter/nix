{ lib, pkgs, ... }: {
  home.stateVersion = "24.05";
  programs.home-manager.enable = true; # let it manage itself

  # url: 127.0.0.1:8384
  services.syncthing.enable = true;
  services.git-sync.enable = true;

  programs.firefox = import ./programs/firefox.nix { inherit pkgs; inherit lib; };
  programs.thunderbird = import ./programs/thunderbird.nix { inherit pkgs; };
  programs.alacritty = import ./programs/alacritty.nix;
  programs.ssh = import ./programs/ssh.nix;
  programs.zsh = import ./programs/zsh.nix;
  programs.emacs = import ./programs/emacs.nix { inherit pkgs; };
  programs.nixvim = import ./programs/nixvim.nix { inherit pkgs; };
  programs.tmux = import ./programs/tmux.nix { inherit pkgs; };
  programs.git = import ./programs/git.nix { inherit pkgs; };
  programs.gh.enable = true;
  programs.gh-dash.enable = true;
  programs.jq.enable = true;
  programs.less.enable = true;
  programs.sioyek.enable = true;
  programs.password-store.enable = true;

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
    git-pw
    git-review
    gnupg
    htop
    iterm2
    lima
    obsidian
    podman
    python312Packages.ipython
    raycast
    slack
    spotify
    telegram-desktop
    tig
    watch
    (import ./modules/devnest.nix { inherit pkgs; })
    (import ./modules/vpn.nix { inherit pkgs; })
  ];

  # Use homebrew ssh for git. It supports gss.
  home.sessionVariables = {
    GIT_SSH_COMMAND = "ssh";
    BROWSER = "firefox";
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

  # TODO: use native readline module for inputrc
  home.file.".inputrc".source = ./dotfiles/inputrc;
  home.file.".iterm2/com.googlecode.iterm2.plist".source = ./dotfiles/iterm2.plist;
  home.file.".bin/alacritty-new-window.sh" = import ./modules/alacritty-new-window.nix { inherit pkgs; };
}
