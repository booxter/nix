{ lib, pkgs, isPrivate, isDesktop, ... }:
{
  programs.zsh = {
    enable = true;
    defaultKeymap = "viins";

    autosuggestion = {
      enable = true;
      strategy = [
        "match_prev_cmd"
        "completion"
      ];
    };

    syntaxHighlighting.enable = true;

    initContent = ''
      [ -f /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
      bindkey "^R" history-incremental-search-backward
    '';

    envExtra = ''
      # Reinitialize SSH_AUTH_SOCK in tmux on reconnect
      # from: @tom-wiley-cotton/nix-config
      if [ -n "$TMUX" ]; then
        function refresh {
          export $(tmux show-environment | grep "^SSH_AUTH_SOCK") > /dev/null
        }
      else
        function refresh { }
      fi

      function preexec {
         refresh
      }
    '';

    # TODO: can I apply aliases for all shells?
    shellAliases =
      let
        openaiKey = "${pkgs.pass}/bin/pass priv/openai-chatgpt-secret";
      in
      {
        aider = "OPENAI_API_KEY=$(${openaiKey}) aider --no-gitignore --model openai/gpt-4.1 --no-attribute-author --no-attribute-committer";

        # enable hyperlinks in kitty
        rg = "rg --hyperlink-format=kitty";

        # cat images in kitty
        icat = "kitten icat";

        # beatify ls
        ll = "ls --hyperlink=auto --color=auto -Fal";
        ls = "ls --hyperlink=auto --color=auto -F";

        # eza
        q = "eza";
        qq = "eza -l";

        view = "nvim -R";
      };
  };

  # eza, ls alternative (`q` and `qq` aliases set for shell)
  programs.eza = {
    enable = true;
    git = true;
    icons = "auto";
    extraOptions = [
      "--group-directories-first"
      "--header"
      "--hyperlink"
      "--follow-symlinks"
    ];
  };

  programs.jq.enable = true;
  programs.less.enable = true;

  # passwords
  programs.password-store.enable = true;

  # starship prompt
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    # starship preset gruvbox-rainbow > ./modules/home-manager/config/starship.toml
    settings = (with builtins; fromTOML (readFile ./starship.toml));
  };

  home.packages = with pkgs; [
    (ripgrep.override { withPCRE2 = true; })
    ack
    aider-chat
    bind.dnsutils
    coreutils
    curl
    dig
    fd
    file
    findutils
    fzf
    gnugrep
    gnumake
    gnupg
    gnused
    go
    gzip
    htop
    hydra-check
    ipcalc
    jinjanator
    kind
    krew
    kubectl
    kubernetes-helm
    lima
    lnav # log viewer
    magic-wormhole
    man-pages
    mc
    moreutils
    ngrep
    nix-init
    nix-search-cli
    nix-tree
    openssh
    openssl
    page
    podman
    pre-commit
    procps
    pstree
    skopeo
    speedtest-cli
    tcpdump
    tree
    unzip
    viddy
    watch
    yq
    zip
    zstd

    # python
    python312Full
    python312Packages.ipython
    python312Packages.tox
  ];

  home.sessionVariables = {
    PAGER = "page -WO -q 90000";
    MANPAGER = "page -t man";
    TERM = "kitty";
  };

  home.file = {
    # TODO: use native readline module for inputrc
    ".inputrc".source = ./inputrc;
  };
}
