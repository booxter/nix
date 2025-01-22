{ lib, pkgs, username, ... }: with lib; {
  home.stateVersion = "25.05";
  programs.home-manager.enable = true; # let it manage itself

  programs.ssh = import ./programs/ssh.nix;
  programs.zsh = import ./programs/zsh.nix { inherit pkgs; };
  programs.nixvim = import ./programs/nixvim.nix { inherit pkgs; };
  programs.tmux = import ./programs/tmux.nix { inherit pkgs; };
  programs.mercurial = {
    enable = true;
    userName = "ihar.hrachyshka";
    userEmail = "ihar.hrachyshka@gmail.com";
  };
  programs.git = import ./programs/git.nix { inherit lib pkgs username; };
  programs.gh = {
    enable = true;
    extensions = with pkgs; [  gh-copilot gh-poi ];
  };
  programs.gh-dash = {
    enable = true;
    settings = {
      repoPaths = {
        ":owner/:repo" = "~/src/:repo";
      };
    };
  };
  programs.eza = import ./programs/eza.nix;
  programs.jq.enable = true;
  programs.less.enable = true;
  programs.password-store.enable = true;

  programs.awscli.enable = true;

  home.packages = with pkgs; [
    ack
    arcanist
    chatgpt-cli
    coreutils
    curl
    discord
    fd
    file
    findutils
    flox
    fzf
    gcalcli
    git-absorb
    git-prole
    git-pw
    git-review
    gmailctl
    gnugrep
    gnupg
    gzip
    heimdal
    htop
    ipcalc
    jq
    less
    lima
    lnav # log viewer
    magic-wormhole
    mailsend-go
    man-pages
    mc
    mergiraf
    moreutils
    neofetch
    ngrep
    nixpkgs-review
    nix-tree
    nurl
    page
    podman
    procps
    pstree
    python311Full
    python311Packages.ipython
    python311Packages.tox
    (ripgrep.override { withPCRE2 = true; })
    shell-gpt
    tcpdump
    tig
    tree
    unzip
    viddy
    watch
    wireshark
    zip
    (import ./modules/meetings.nix { inherit pkgs; })
    (import ./modules/openstack-logs.nix { inherit pkgs; })
    (import ./modules/weechat-session.nix { inherit pkgs; })
    (import ./modules/spot.nix { inherit pkgs; })
    (import ./modules/aws-automation.nix { inherit pkgs; })
  ]
  ++ lib.optionals stdenv.isDarwin [
    cb_thunderlink-native
    element-desktop
    iterm2
    keycastr
    obsidian
    podman-desktop
    raycast
    slack
    spotify
    todoist
    (import ./modules/beaker.nix { inherit pkgs lib; })
    (import ./modules/devnest.nix { inherit pkgs; })
    (import ./modules/rhpkg.nix { inherit pkgs; })
    (import ./modules/homerow.nix { inherit pkgs lib; })
    (import ./modules/vpn.nix { inherit pkgs; })
    # TODO: maybe add a launchd service to clean up periodically?
    (import ./modules/clean-uri-handlers.nix { inherit pkgs username; })
  ] ++ lib.optionals stdenv.isDarwin builtins.filter lib.attrsets.isDerivation (builtins.attrValues pkgs.nerd-fonts);

  programs.spotify-player.enable = true;

  programs.vscode = {
    enable = true;
    enableExtensionUpdateCheck = false;
    enableUpdateCheck = false;
    mutableExtensionsDir = false; # at least for now
  };

  fonts.fontconfig.enable = true;

  home.sessionVariables = {
    # Use homebrew ssh for git. It supports gss.
    GIT_SSH_COMMAND = "ssh";
    BROWSER = "open";
    PAGER = "page -WO -q 90000";
    MANPAGER = "page -t man";
    HOMEBREW_NO_AUTO_UPDATE = 1;
    AWS_PROFILE = "saml";
  };

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    # starship preset gruvbox-rainbow > ./modules/home-manager/config/starship.toml
    settings = (with builtins; fromTOML (readFile ./config/starship.toml));
  };

  accounts.email.accounts = import ./config/email.nix { inherit pkgs; };
  programs.msmtp.enable = true;

  # TODO: move darwin specific config files to a separate module?
  home.file = {
    # TODO: use native readline module for inputrc
    ".inputrc".source = ./dotfiles/inputrc;

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
    ".bin/terminal-new-window.sh" = import ./modules/terminal-new-window.nix { inherit pkgs; };
  };
}
