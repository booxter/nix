{
  config,
  pkgs,
  isWork,
  ...
}:
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

  # cli password manager
  programs.password-store = {
    enable = true;
    settings = {
      # Restore pass location to what was before https://github.com/nix-community/home-manager/pull/7833
      PASSWORD_STORE_DIR = "${config.xdg.dataHome}/password-store";
    };
  };

  # starship prompt
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    # starship preset gruvbox-rainbow > ./modules/home-manager/config/starship.toml
    settings = fromTOML (builtins.readFile ./starship.toml);
  };

  home.packages =
    with pkgs;
    [
      (ripgrep.override { withPCRE2 = true; })
      ack
      act
      bc
      curl
      delve # go debugger
      devenv
      fd
      fzf
      gnupg
      go
      hydra-check
      lima
      lnav # log viewer
      mkpasswd
      (my-page.override { neovim = config.programs.nixvim.build.package; })
      nix-init
      nix-search-cli
      nix-tree
      nurl
      openssl
      podman
      pre-commit
      wget
      yq-go
      zstd

      # python
      python313
      python313Packages.ipython
      python313Packages.tox
    ]
    ++ lib.optionals (!isWork) [
      aider-chat
      ramalama
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
