{ username, ... }:
{
  system.defaults = {
    dock = {
      autohide = true;
      autohide-delay = 0.0;
      autohide-time-modifier = 0.0;
      orientation = "right";
      persistent-apps = [
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
      _FXShowPosixPathInTitle = false;
      ShowPathbar = true;
      ShowStatusBar = true;
    };

    CustomUserPreferences = {
      "com.apple.Terminal" = {
        # skhd requires Secure Keyboard Entry to be disabled.
        "SecureKeyboardEntry" = false;
      };
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

      # Enable the 'Input menu' in the top right corner of the screen
      "com.apple.TextInputMenu".visible = 1;

      # use Caps Lock to switch between layouts
      NSGlobalDomain.TISRomanSwitchState = 1;

    };

    screensaver.askForPasswordDelay = 10;

    trackpad.Clicking = true;
    NSGlobalDomain = {
      "com.apple.mouse.tapBehavior" = 1;
      InitialKeyRepeat = 14;
      KeyRepeat = 1;
      AppleInterfaceStyle = "Dark";

      AppleShowAllFiles = true;

      NSAutomaticSpellingCorrectionEnabled = false;
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticPeriodSubstitutionEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;

      # hide menu bar
      _HIHideMenuBar = true;
    };
  };
}
