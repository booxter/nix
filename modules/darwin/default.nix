{ self, pkgs, ... }: let
  kinit-pass = "${(import ../../modules/home-manager/modules/kinit-pass.nix { inherit pkgs; })}/bin/kinit-pass";
in rec {
  # TODO: use launchd.user.agents.iterm2.serviceConfig instead?
  environment.userLaunchAgents.iterm2 = {
    source = ./dotfiles/iterm2-login.plist;
    target = "iterm2.plist";
  };
  # TODO: untangle setting of PASSWORD_STORE_DIR from user name
  environment.userLaunchAgents.kinit-pass = {
    text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>kinit-pass</string>
          <key>ProgramArguments</key>
          <array>
              <string>${kinit-pass}</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
              <key>PASSWORD_STORE_DIR</key>
              <string>/Users/ihrachys/.local/share/password-store</string>
          </dict>
          <key>StartInterval</key>
          <integer>${toString (60 * 60 * 8)}</integer>
      </dict>
      </plist>
    '';
    target = "kinit-pass.plist";
  };

  # clean up old nix derivations
  nix.gc.automatic = true;
  nix.optimise.automatic = true;

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;
  # nix.package = pkgs.nix;

  # Necessary for using flakes on this system.
  nix.settings.experimental-features = "nix-command flakes";

  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs; [
    coreutils
    defaultbrowser
  ];

  homebrew = import ./modules/homebrew.nix;
  services.spotifyd = import ./modules/spotifyd.nix { inherit pkgs; };
  services.jankyborders = import ./modules/jankyborders.nix;

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
  system.defaults = import ./modules/defaults.nix { inherit pkgs; home = users.users.ihrachys.home; };

  security.pam.enableSudoTouchIdAuth = true;
  security.sudo.extraConfig = "Defaults    timestamp_timeout=30";

  system.activationScripts.postUserActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    defaultbrowser firefox
  '';
}
