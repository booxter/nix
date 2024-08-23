{ pkgs, home, ... }: {
  dock = {
    autohide = true;
    autohide-delay = 0.0;
    autohide-time-modifier = 0.0;
    orientation = "right";
    persistent-apps = [
      "${pkgs.alacritty}/Applications/Alacritty.app"
      "${home}/Applications/Firefox.app"
      "${pkgs.slack}/Applications/Slack.app"
      "${pkgs.telegram-desktop}/Applications/Telegram.app"
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
        {
          id = "com.apple.systempreferences";
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

    "com.superultra.Homerow" = {
      SUEnableAutomaticChecks = 0;
      SUHasLaunchedBefore = 1;
      "check-for-updates-automatically" = 0;
      "is-experimental-support-enabled" = 0;
      "launch-at-login" = 1;
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
}
