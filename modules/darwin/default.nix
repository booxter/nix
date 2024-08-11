{ self, pkgs, ... }: {
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = [ pkgs.coreutils ];

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  # nix.package = pkgs.nix;

  # Necessary for using flakes on this system.
  nix.settings.experimental-features = "nix-command flakes";

  homebrew = {
    enable = true;
    onActivation.autoUpdate = false;
    brews = [ "openssh" ];
    casks = [ "amethyst" ];
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

  users.users.ihrachys = {
    name = "ihrachys";
    home = "/Users/ihrachys";
  };

  security.pam.enableSudoTouchIdAuth = true;
  security.sudo.extraConfig = "Defaults    timestamp_timeout=30";

  system.activationScripts.postUserActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';

  system.defaults = {
    dock = {
      autohide = true;
      orientation = "right";
      persistent-apps = [
        "/Applications/Safari.app"
        "${pkgs.alacritty}/Applications/Alacritty.app"
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
    };

    screensaver.askForPasswordDelay = 10;

    NSGlobalDomain."com.apple.mouse.tapBehavior" = 1;
    trackpad.Clicking = true;
    NSGlobalDomain.InitialKeyRepeat = 14;
    NSGlobalDomain.KeyRepeat = 1;
  };
}
