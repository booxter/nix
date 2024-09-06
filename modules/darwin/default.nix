{ pkgs, username, ... }: let
  kinit-pass = "${(import ./modules/kinit-pass.nix { inherit pkgs; })}/bin/kinit-pass";
in rec {

  # Needed for firefox and thunderbird to work with read-only profiles.ini
  # managed by home-manager; update if/when https://github.com/LnL7/nix-darwin/issues/1056
  # is fixed.
  launchd.user.envVariables = {
    MOZ_LEGACY_PROFILES = "1";
    MOZ_ALLOW_DOWNGRADE = "1";
  };

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
              <string>/Users/${username}/.local/share/password-store</string>
          </dict>
          <key>StartInterval</key>
          <integer>${toString (60 * 60 * 8)}</integer>
          <key>RunAtLoad</key>
          <true/>
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
  services.emacs.enable = true;

  # TODO: understand why sometimes I have to `pkill gpg-agent`
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true;  # default shell on catalina

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  fonts.packages = [ pkgs.nerdfonts ];

  users.users.${username} = {
    name = username;
    home = "/Users/${username}";
  };
  system.defaults = import ./modules/defaults.nix { inherit pkgs username; home = users.users.${username}.home; };

  # Disable nix-darwin implementation because it doesn't configure reattach
  security.pam.enableSudoTouchIdAuth = false;
  environment.etc."pam.d/sudo_local".text = ''
    # PAM for tmux touchid; must go before _tid.so
    auth       optional     ${pkgs.pam-reattach}/lib/pam/pam_reattach.so
    # Base touchid pam module
    auth       sufficient   pam_tid.so
  '';

  security.sudo.extraConfig = "Defaults    timestamp_timeout=30";

  system.activationScripts.postUserActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    defaultbrowser firefox
  '';
  system.activationScripts.postActivation.text = ''
    # don't sleep when plugged
    sudo pmset -c sleep 0
    # disable power nap to avoid unnecessary irc reconnects
    sudo pmset -a powernap 0
  '';
}
