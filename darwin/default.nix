{
  hostname,
  lib,
  pkgs,
  username,
  platform,
  stateVersion,
  isDesktop,
  isWork,
  ...
}:
{
  imports =
    lib.optionals (builtins.pathExists ./${hostname}) [
      ./${hostname}
    ]
    ++ [
      ./_mixins/defaults
      ./_mixins/fonts
      ./_mixins/fleet-cache-warmer
      ./_mixins/homebrew
      ./_mixins/internal-pki
      ./_mixins/lan-wan-accounting
      ./_mixins/logs-client
      ./_mixins/networking
      ./_mixins/nix-gc
      ./_mixins/observability-client
      ./_mixins/sketchybar-alertmanager
      ./_mixins/sudo
      ./_mixins/thermal-accounting
      ./_mixins/xquartz
    ]
    ++ lib.optionals (!isWork) [
      ./_mixins/attic
      ./_mixins/browser
    ]
    ++ lib.optionals isWork [
      ./_mixins/docker-desktop
    ]
    ++ lib.optionals (hostname == "mair") [
      ./_mixins/secretive
    ];

  nixpkgs.hostPlatform = lib.mkDefault platform;

  system.stateVersion = stateVersion;

  host.xquartz.enable = lib.mkDefault (!isWork && isDesktop);

  system.primaryUser = username;

  users.users.${username} = {
    home = "/Users/${username}";
    createHome = true;
    description = "Ihar Hrachyshka";
    shell = pkgs.zsh;
  };

  system.defaults.smb = lib.optionalAttrs (!isWork) {
    NetBIOSName = hostname;
    ServerDescription = hostname;
  };

  system = {
    activationScripts.postActivation.text = ''
      echo "Do not idle sleep or hibernate when on AC power."
      pmset -c sleep 0 disksleep 0 standby 0 powernap 0 hibernatemode 0

      echo "Prefer network over sleep."
      pmset networkoversleep 1
    '';
  };

  launchd.daemons.prevent-ac-sleep = {
    command = "/usr/bin/caffeinate -s";
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "/var/log/prevent-ac-sleep.log";
      StandardErrorPath = "/var/log/prevent-ac-sleep.log";
    };
  };

  # TODO: is it still needed? Does it operate in the user context? (Not root?)
  system.activationScripts.userActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
