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
      echo "Do not sleep when on AC power."
      pmset -c sleep 0 # Needs testing - UI not immediately updated.

      echo "Prefer network over sleep."
      pmset networkoversleep 1
    '';
  };

  # TODO: is it still needed? Does it operate in the user context? (Not root?)
  system.activationScripts.userActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
