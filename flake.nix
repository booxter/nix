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
      # environment.systemPackages = [ pkgs.git ];

      # Auto upgrade nix package and the daemon service.
      services.nix-daemon.enable = true;
      # nix.package = pkgs.nix;

      # Necessary for using flakes on this system.
      nix.settings.experimental-features = "nix-command flakes";

      nixpkgs.config = { allowUnfree = true; };

      homebrew.enable = true;
      homebrew.onActivation.autoUpdate = true;

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

      users.users.ihrachys = {
        name = "ihrachys";
        home = "/Users/ihrachys";
      };

      # TODO: not working in Sonoma, yet: https://github.com/LnL7/nix-darwin/pull/787
      security.pam.enableSudoTouchIdAuth = true;

      system.defaults = {
        dock.autohide = true;
        dock.orientation = "right";
        dock.persistent-apps = [
          "/Applications/Safari.app"
          "/System/Applications/Utilities/Terminal.app"
        ];
        dock.tilesize = 32;
        dock.show-recents = false;
        dock.mru-spaces = false; # disable most recent apps affecting the dock items order

        finder.AppleShowAllExtensions = true;
        finder.CreateDesktop = false; # don't show files on desktop
        finder.FXPreferredViewStyle = "clmv"; # column view
        finder.QuitMenuItem = true; # allow to exit
        finder._FXShowPosixPathInTitle = true;
        finder.ShowPathbar = true;
        finder.ShowStatusBar = true;

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
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "backup";

          home-manager.users.ihrachys = { pkgs, ... }: {
            home.stateVersion = "24.05";
            programs.home-manager.enable = true; # let it manage itself

            programs.git.enable = true;
            programs.git.package = pkgs.gitAndTools.gitFull;
            programs.git.userEmail = "ihar.hrachyshka@gmail.com";
            programs.git.userName = "Ihar Hrachyshka";
            programs.gh.enable = true;

            home.packages = [ pkgs.gitAndTools.gitFull ];

            programs.zsh.enable = true;
            programs.zsh = {
              initExtra = ''
                eval "$(/opt/homebrew/bin/brew shellenv)"
              '';
            };

            programs.ssh.enable = true;
            programs.ssh.forwardAgent = true;
            # programs.ssh.includes = [ "config.backup" ];
          };
        }
      ];
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."ihrachys-macpro".pkgs;
  };
}
