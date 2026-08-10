{
  config,
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  inherit (osConfig.host) isDarwin;
  userEnvironment = osConfig.host.userEnvironment;
  cliCfg = userEnvironment.features.cli;
  repositoryCatalog = userEnvironment.repositories.catalog;
  requiredRepositories = userEnvironment.repositories.required;
  homeManagerPkgs = import ../../pkgs pkgs;
  cliPkgs = import ./pkgs { inherit pkgs; };
  repositoryPath =
    repository:
    let
      basePath =
        {
          home = config.home.homeDirectory;
          xdgData = config.xdg.dataHome;
        }
        .${repository.destination.base};
    in
    "${basePath}/${repository.destination.path}";
  syncRepoConfig = (pkgs.formats.json { }).generate "sync-repo.json" {
    repositories = builtins.listToAttrs (
      map (name: {
        inherit name;
        value = {
          inherit (repositoryCatalog.${name}) remote;
          path = repositoryPath repositoryCatalog.${name};
        };
      }) requiredRepositories
    );
  };
  syncRepo = pkgs.symlinkJoin {
    name = "sync-repo-configured";
    paths = [ cliPkgs.sync-repo ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/sync-repo" --add-flags ${lib.escapeShellArg "--config ${syncRepoConfig}"}
    '';
  };
  nr = cliPkgs.nr.override {
    builders = osConfig.host.nix.nixpkgs-review.builders;
  };
in
{
  programs.bash.enable = true;

  home.shellAliases = {
    # Beautify ls output.
    ll = "ls --hyperlink=auto --color=auto -Fal";
    ls = "ls --hyperlink=auto --color=auto -F";

    view = "vim -R";

    # enable hyperlinks in kitty
    rg = "rg --hyperlink-format=kitty";

    # cat images in kitty
    icat = "kitten icat";

    # eza
    q = "eza";
    qq = "eza -l";
  };

  programs.zsh = {
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

      autoload -U compinit
      ZSH_COMPDUMP="${config.xdg.cacheHome}/zsh/zcompdump-$ZSH_VERSION"
      mkdir -p "$(dirname "$ZSH_COMPDUMP")"
      if [[ -f "$ZSH_COMPDUMP" ]]; then
        compinit -d "$ZSH_COMPDUMP" -C
      else
        compinit -d "$ZSH_COMPDUMP"
      fi
    '';

    envExtra = ''
      ${lib.optionalString isDarwin ''
        # Repair shells that inherit the Nix initialization guards without the
        # corresponding profile paths, such as Terminal launched by Codex.
        if [[ ":$PATH:" != *":/run/current-system/sw/bin:"* ]]; then
          export PATH="$HOME/.priv-bin:$HOME/.nix-profile/bin:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/sbin:/sbin:$PATH"
        fi
      ''}

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
  programs.password-store = lib.mkIf cliCfg.passwordStore.enable {
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
    settings = fromTOML (builtins.readFile ./starship.toml);
  };

  home.packages =
    with pkgs;
    [
      (ripgrep.override { withPCRE2 = true; })
      ack
      act
      cliPkgs.attention-inbox
      bc
      curl
      delve # go debugger
      devenv
      fd
      fzf
      cliPkgs.gh-restart-failed-jobs
      gnupg
      go
      hydra-check
      (lima.override { withAdditionalGuestAgents = true; })
      mkpasswd
      (homeManagerPkgs.page.override { neovim = config.programs.nixvim.build.package; })
      nh
      nix-init
      nix-output-monitor
      nix-search-cli
      nix-tree
      nixpkgs-reviewFull
      nr
      nurl
      openssl
      pre-commit
      wget
      yq-go
      yubikey-manager
      zstd

      # python
      python313
    ]
    ++ lib.optionals isDarwin [
      container
    ]
    ++ lib.optionals (requiredRepositories != [ ]) [
      syncRepo
    ]
    ++ lib.optionals cliCfg.ramalama.enable [
      ramalama
    ];

  home.sessionVariables = {
    PAGER = "page -WO -q 90000";
    MANPAGER = "page -t man";
  };

  home.sessionPath = [
    "$HOME/.priv-bin"
  ];

  home.file = {
    # TODO: use native readline module for inputrc
    ".inputrc".source = ./inputrc;
  };

  home.activation.clearZshCompdump = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    rm -f "${config.xdg.cacheHome}/zsh/zcompdump-"*
  '';
}
