{ lib, pkgs, username, ... }: let
  kinit-pass = "${(import ./modules/kinit-pass.nix { inherit pkgs; })}/bin/kinit-pass";
in rec {
  # TODO: use launchd.user.agents.iterm2.serviceConfig instead?
  environment.userLaunchAgents.iterm2 = {
    source = ./dotfiles/iterm2-login.plist;
    target = "iterm2.plist";
  };
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

  # launchd.user.agents.activate-user = {
  #   command = "/run/current-system/activate-user";
  #   serviceConfig.RunAtLoad = true;
  #   serviceConfig.KeepAlive.SuccessfulExit = false;
  # };

  # clean up old nix derivations
  nix.gc.automatic = true;
  nix.gc.interval = [
    {
      Hour = 3;
      Minute = 15;
      Weekday = 1;
    }
  ];
  nix.optimise.automatic = true;
  nix.optimise.interval = lib.lists.forEach nix.gc.interval (e: {
    inherit (e) Minute Weekday;
    Hour = e.Hour + 1; # an hour later
  });

  # enable linux package builds via a local-remote vm
  nix = {
    linux-builder = {
      enable = true;
      ephemeral = true;
      maxJobs = 4;
      config = {
        virtualisation = {
          darwin-builder = {
            diskSize = 40 * 1024;
            memorySize = 8 * 1024;
          };
          cores = 6;
        };
    };
    };
    settings = {
      trusted-users = [ "@admin" ];
      # Try to avoid: "warning: download buffer is full; consider increasing the 'download-buffer-size' setting"
      download-buffer-size = 1024*1024*256; # 256Mb; default is 64Mb
    };
  };

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
  services.emacs = {
    enable = true;
    package = pkgs.emacs29-pgtk;
  };

  # TODO: not sure if this is needed; was enabled for emacs lsp watchers but
  # the FD_SETSIZE limit probably applies instead
  launchd.daemons = {
    limit-maxfiles = {
      command = "/bin/launchctl limit maxfiles 524288 16777216";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
      };
    };
    limit-maxproc = {
      command = "/bin/launchctl limit maxproc 16704 16704";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
      };
    };
    sysctl = {
      serviceConfig = {
        Program = "/usr/sbin/sysctl";
        ProgramArguments =
          [ "kern.maxfiles=16777216" "kern.maxfilesperproc=16704" ];
        RunAtLoad = true;
        KeepAlive = false;
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
    # don't wake up for network keepalives
    sudo pmset -a tcpkeepalive 0
    # disable power nap to avoid unnecessary network reconnects
    sudo pmset -a powernap 0
    # Disable darkwake to avoid even more of unnecessary network reconnects
    ffdir=/Library/Preferences/FeatureFlags/Domain/
    mkdir -p $ffdir
    cp ${./dotfiles/powerd.plist} $ffdir/powerd.plist
  '';
}
