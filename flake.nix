{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, home-manager, nix-darwin, nixpkgs }:
  let
    configuration = { pkgs, ... }: {
      # List packages installed in system profile. To search by name, run:
      # $ nix-env -qaP | grep wget
      environment.systemPackages = [ pkgs.coreutils ];

      # Auto upgrade nix package and the daemon service.
      services.nix-daemon.enable = true;
      # nix.package = pkgs.nix;

      # Necessary for using flakes on this system.
      nix.settings.experimental-features = "nix-command flakes";

      nixpkgs.config = { allowUnfree = true; };

      homebrew = {
        enable = true;
        onActivation.autoUpdate = false;
        brews = [ "openssh" ];
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

      system.defaults = {
        dock = {
          autohide = true;
          orientation = "right";
          persistent-apps = [
            "/Applications/Safari.app"
            "/System/Applications/Utilities/Terminal.app"
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
      };
    };
  in
  {
    # Build darwin flake using:
    # $ darwin-rebuild build --flake .#
    darwinConfigurations."ihrachys-macpro" = nix-darwin.lib.darwinSystem {
      modules = [
        configuration
        home-manager.darwinModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "backup";
          };

          home-manager.users.ihrachys = { pkgs, ... }: {
            home.stateVersion = "24.05";
            programs.home-manager.enable = true; # let it manage itself

            programs.git.enable = true;
            programs.git.package = pkgs.gitAndTools.gitFull;
            programs.git.userEmail = "ihar.hrachyshka@gmail.com";
            programs.git.userName = "Ihar Hrachyshka";
            programs.gh.enable = true;

            programs.tmux.enable = true;
            programs.tmux.terminal = "tmux-256color";
            programs.tmux.historyLimit = 100000;

            home.packages = [ pkgs.gitAndTools.gitFull ];

            home.sessionVariables = {
              EDITOR = "nvim";
            };
            programs.neovim.enable = true;

            programs.zsh = {
              enable = true;
              initExtra = ''
                eval "$(/opt/homebrew/bin/brew shellenv)"
              '';
            };

            programs.ssh = {
              enable = true;
              forwardAgent = true;
              includes = [ "config.backup" ];
            };
          };
        }
      ];
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."ihrachys-macpro".pkgs;
  };
}
