{ lib, pkgs, ... }: {
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
        # TODO: pass name as argument
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

  programs.password-store.enable = true;
  services.git-sync = {
    enable = true;
    repositories = {
      password-store = {
        uri = "git+ssh://booxter@github.com:booxter/pass.git";
        # TODO: pass name as argument
        path = "/Users/ihrachys/.local/share/password-store";
        interval = 30;
      };
    };
  };
  home.activation = {
    makePotato = lib.hm.dag.entryAfter ["writeBoundary"] ''
    GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh ${pkgs.git}/bin/git clone git@github.com:booxter/pass.git ~/.local/share/password-store || true
    cd ~/.local/share/password-store && ${pkgs.git}/bin/git config --bool branch.master.sync true
    '';
  };

  home.packages = with pkgs; [
    git-pw
    gnupg
    iterm2
    python312Packages.ipython
    raycast
    slack
    spotify
    telegram-desktop
    tig

    (pkgs.writeScriptBin "vpn" ''
    osascript << EOF
      tell application "Viscosity"
      if the state of the first connection is "Connected" then
        disconnect "Red Hat Global VPN"
      else
        connect "Red Hat Global VPN"
      end if
      end tell
    EOF
    '')
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

  targets.darwin.defaults."com.apple.Safari" = {
    AutoFillCreditCardData = true;
    AutoFillPasswords = true;
    IncludeDevelopMenu = true;
    ShowOverlayStatusBar = true;
  };

  programs.firefox = {
    enable = true;
    # using homebrew firefox
    package = null;
    profiles.default = {
      search.default = "DuckDuckGo";
      search.privateDefault = "DuckDuckGo";
      search.force = true;
      settings = {
        "extensions.autoDisableScopes" = 0;
        "browser.aboutConfig.showWarning" = false;
        "browser.ctrlTab.sortByRecentlyUsed" = false;
        "browser.translations.neverTranslateLanguages" = "en,ru,be,uk,cz,pl";
        "browser.tabs.crashReporting.sendReport" = false;
        "accessibility.typeaheadfind.enablesound" = false;

        "browser.startup.homepage" = "";

        "geo.enabled" = true;
        "privacy.clearOnShutdown.history" = false;
        "privacy.donottrackheader.enabled" = true;
        "privacy.trackingprotection.enabled" = true;
        "privacy.trackingprotection.socialtracking.enabled" = true;
        "device.sensors.enabled" = false;
        "beacon.enabled" = false; # bluetooth location tracking

        # don't allow mozilla to test config changes
        "app.normandy.enabled" = false;
        "app.shield.optoutstudies.enabled" = false;

        # telemetry
        "browser.send_pings" = false;
        "toolkit.telemetry.archive.enabled" = false;
        "toolkit.telemetry.enabled" = false;
        "toolkit.telemetry.server" = "";
        "toolkit.telemetry.unified" = false;
        "extensions.webcompat-reporter.enabled" = false;
        "datareporting.policy.dataSubmissionEnabled" = false;
        "datareporting.healthreport.uploadEnabled" = false;
        "browser.ping-centre.telemetry" = false;
        "browser.urlbar.eventTelemetry.enabled" = false; # (default)

        # Disable some useless stuff
        "extensions.pocket.enabled" = false; # disable pocket, save links, send tabs
        "extensions.abuseReport.enabled" = false; # don't show 'report abuse' in extensions
        "identity.fxaccounts.enabled" = false; # disable firefox login
        "identity.fxaccounts.toolbar.enabled" = false;
        "identity.fxaccounts.pairing.enabled" = false;
        "identity.fxaccounts.commands.enabled" = false;
        "browser.contentblocking.report.lockwise.enabled" = false; # don't use firefox password manager
        "browser.uitour.enabled" = false; # no tutorial please
        "browser.newtabpage.activity-stream.showSponsored" = false;
        "browser.newtabpage.activity-stream.showSponsoredTopSites" = false;

        # disable annoying web features
        "dom.push.enabled" = false; # push notifications
        "dom.push.connection.enabled" = false;
        "dom.battery.enabled" = false; # you don't need to see my battery...
        "dom.private-attribution.submission.enabled" = false; # No PPA

        # krb gss login
        "network.negotiate-auth.trusted-uris" = "redhat.com";
      };
      extensions = with pkgs.nur.repos.rycee.firefox-addons; [
        privacy-badger
        ublock-origin
        vimium
      ];
    };
  };

  home.file.".inputrc".source = ./dotfiles/inputrc;
  home.file.".iterm2/com.googlecode.iterm2.plist".source = ./dotfiles/iterm2.plist;
}
