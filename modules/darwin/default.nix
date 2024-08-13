{ self, pkgs, ... }: rec {
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    coreutils
    defaultbrowser
  ];

  # TODO: use launchd.user.agents.iterm2.serviceConfig instead?
  environment.userLaunchAgents.iterm2 = {
    source = ./dotfiles/iterm2-login.plist;
    target = "iterm2.plist";
  };

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  # nix.package = pkgs.nix;

  # Necessary for using flakes on this system.
  nix.settings.experimental-features = "nix-command flakes";

  homebrew = {
    enable = true;
    onActivation.autoUpdate = false;
    brews = [ "openssh" ];
    casks = [
      "amethyst"
      "thunderbird"
      {
        name = "firefox";
        args = {
          appdir = "~/Applications";
          no_quarantine = true;
        };
      }
    ];
  };

  services.spotifyd = {
    enable = true;
    package = (pkgs.spotifyd.override { withKeyring = true; });
    settings = {
      global = {
        # security add-generic-password -s spotifyd -D rust-keyring -a <your username> -w <your password>
        username = "11126800926";
        use_keyring = true;
        device_name = "nix";
        device_type = "computer";
      };
    };
  };

  # TODO: understand why sometimes I have to `pkill gpg-agent`
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true;  # default shell on catalina
  # programs.fish.enable = true;

  # Set Git commit hash for darwin-version.
  system.configurationRevision = self.rev or self.dirtyRev or null;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  # The platform the configuration will be used on.
  nixpkgs.hostPlatform = "aarch64-darwin";

  fonts.packages = [ pkgs.nerdfonts ];

  # TODO: pass name as argument
  users.users.ihrachys = rec {
    name = "ihrachys";
    home = "/Users/${name}";
  };

  security.pam.enableSudoTouchIdAuth = true;
  security.sudo.extraConfig = "Defaults    timestamp_timeout=30";

  system.activationScripts.postUserActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    defaultbrowser firefox
  '';

  system.defaults = {
    dock = {
      autohide = true;
      orientation = "right";
      persistent-apps = [
        "${pkgs.alacritty}/Applications/Alacritty.app"
        "${users.users.ihrachys.home}/Applications/Firefox.app"
        "${pkgs.slack}/Applications/Slack.app"
        "${pkgs.spotify}/Applications/Spotify.app"
      ];
      tilesize = 32;
      show-recents = false;
      mru-spaces = false; # disable most recent apps affecting the dock items order
    };

    finder = {
      AppleShowAllExtensions = true;
      CreateDesktop = false; # don't show files on desktop
      FXPreferredViewStyle = "clmv"; # column view
      QuitMenuItem = true; # allow to exit
      _FXShowPosixPathInTitle = true;
      ShowPathbar = true;
      ShowStatusBar = true;
    };

    CustomUserPreferences = {
      "com.apple.loginwindow" = {
        TALLogoutSavesState = 0;
      };
      "com.apple.finder" = {
        _FXSortFoldersFirst = true;
      };
      "com.apple.desktopservices" = {
        # Avoid creating .DS_Store files on network or USB volumes
        DSDontWriteNetworkStores = true;
        DSDontWriteUSBStores = true;
      };
      "com.apple.print.PrintingPrefs" = {
        # Automatically quit printer app once the print jobs complete
        "Quit When Finished" = true;
      };
      "com.apple.SoftwareUpdate" = {
        AutomaticCheckEnabled = true;
        # Check for software updates daily, not just once per week
        ScheduleFrequency = 1;
        # Download newly available updates in background
        AutomaticDownload = 1;
        # Install System data files & security updates
        CriticalUpdateInstall = 1;
      };
      "com.amethyst.Amethyst" = {
        # Amethyst is messing with iterm2 quake window otherwise
        floating = [
          {
            id = "com.googlecode.iterm2";
            window-titles = [ ];
          }
        ];
      };
      "com.googlecode.iterm2" = {
        PrefsCustomFolder = "/Users/ihrachys/.iterm2";
        NoSyncNeverRemindPrefsChangesLostForFile_selection = 1; # Manually save changes
      };
      "com.apple.HIToolbox" = {
        AppleEnabledInputSources = [
          {
            InputSourceKind = "Keyboard Layout";
            "KeyboardLayout ID" = 0;
            "KeyboardLayout Name" = "U.S.";
          }
          {
            InputSourceKind = "Keyboard Layout";
            "KeyboardLayout ID" = 19517;
            "KeyboardLayout Name" = "Byelorussian";
          }
          {
            InputSourceKind = "Keyboard Layout";
            "KeyboardLayout ID" = 19456;
            "KeyboardLayout Name" = "Russian";
          }
          {
            "Bundle ID" = "com.apple.CharacterPaletteIM";
            InputSourceKind = "Non Keyboard Input Method";
          }
          {
            "Bundle ID" = "com.apple.PressAndHold";
            InputSourceKind = "Non Keyboard Input Method";
          }
        ];
      };
    };

    screensaver.askForPasswordDelay = 10;

    trackpad.Clicking = true;
    NSGlobalDomain = {
      "com.apple.mouse.tapBehavior" = 1;
      InitialKeyRepeat = 14;
      KeyRepeat = 1;
      AppleInterfaceStyle = "Dark";
    };
  };
}
