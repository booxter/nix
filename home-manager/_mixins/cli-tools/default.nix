{ config, pkgs, ... }:
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

        # remove once https://github.com/nektos/act/issues/2329 is fixed
        act = "act -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04";
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
    act
    aider-chat
    curl
    fd
    fzf
    gnupg
    gitlab-ci-local
    go
    hydra-check
    jinjanator
    kind
    kubectl
    kubernetes-helm
    lima
    lnav # log viewer
    magic-wormhole
    mc
    mkpasswd
    (my-page.override { neovim = config.programs.nixvim.build.package; })
    nix-init
    nix-search-cli
    nix-tree
    nurl
    openssl
    podman
    pre-commit
    ramalama
    skopeo
    yq
    zstd

    # python
    python313Full
    python313Packages.ipython
    python313Packages.tox
  ];

  home.sessionVariables = {
    PAGER = "page -WO -q 90000";
    MANPAGER = "page -t man";
    CONTAINERS_MACHINE_PROVIDER = "libkrun";
  };

  home.file = {
    # TODO: use native readline module for inputrc
    ".inputrc".source = ./inputrc;
  };
}
