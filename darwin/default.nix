{
  hostname,
  lib,
  pkgs,
  username,
  platform,
  stateVersion,
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
      ./_mixins/homebrew
      ./_mixins/internal-pki
      ./_mixins/lan-wan-accounting
      ./_mixins/logs-client
      ./_mixins/nix-darwin-backports
      ./_mixins/nix-gc
      ./_mixins/observability-client
      ./_mixins/sudo
      ./_mixins/thermal-accounting
    ]
    ++ lib.optionals (!isWork) [
      ./_mixins/attic
      ./_mixins/browser
      ./_mixins/secretive
    ];

  nixpkgs.hostPlatform = lib.mkDefault platform;

  system.stateVersion = stateVersion;

  system.primaryUser = username;

  users.users.${username} = {
    home = "/Users/${username}";
    createHome = true;
    description = "Ihar Hrachyshka";
    shell = pkgs.zsh;
  };

  # Can't configure networking on managed work devices
  networking = lib.optionalAttrs (!isWork) {
    knownNetworkServices =
      # mair - laptop - doesn't have builtin ethernet
      lib.optionals (hostname != "mair") [
        "Ethernet"
      ]
      ++ [
        "Wi-Fi"
      ];
    computerName = hostname;
    dhcpClientId = hostname;
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
