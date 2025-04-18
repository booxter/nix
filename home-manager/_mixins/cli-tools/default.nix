{ pkgs, ... }:
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

    initExtra = ''
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
        gcalcliHome = "gcalcli --config-folder ~/.gcalcli --calendar Home";
        gcalcliWork = "gcalcli --config-folder ~/.gcalcli-rh --calendar ihrachys@redhat.com";
        gcalcliCalwArgs = "calw --military --nodeclined --monday";
      in
      {
        # ai bots
        chatgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) chatgpt";
        sgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) sgpt";

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

        # gmailctl for personal account will use the default config path
        gmailctl-rh = "gmailctl --config=$HOME/.gmailctl-rh";

        view = "nvim -R";

        # google calendar
        gc = "${gcalcliHome}";
        gc-rh = "${gcalcliWork}";
        gcw = "${gcalcliHome} ${gcalcliCalwArgs}";
        gcw-rh = "${gcalcliWork} ${gcalcliCalwArgs}";

        # send weekly report to boss(es)
        report = "~/.priv-bin/weekly-report";
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
    bind.dnsutils
    chatgpt-cli
    coreutils
    curl
    fd
    file
    findutils
    flox
    fzf
    gcalcli
    gnugrep
    gnupg
    gnused
    gzip
    heimdal
    htop
    hydra-check
    ibmcloud-cli
    ipcalc
    lima
    lnav # log viewer
    magic-wormhole
    man-pages
    mc
    mergiraf
    moreutils
    ngrep
    nix-init
    nix-tree
    nom
    nvtopPackages.full
    ollama
    openssh
    page
    podman
    pre-commit
    procps
    pstree
    shell-gpt
    tcpdump
    tree
    unzip
    viddy
    watch
    yubikey-manager
    zip

    # python
    python311Full
    python311Packages.ipython
    python311Packages.tox
  ];

  home.sessionVariables = {
    PAGER = "page -WO -q 90000";
    MANPAGER = "page -t man";
  };

  home.file = {
    # TODO: use native readline module for inputrc
    ".inputrc".source = ./inputrc;
  };
}
