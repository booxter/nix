{
  hostname,
  lib,
  pkgs,
  username,
  platform,
  stateVersion,
  isWork,
  ci ? false,
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
      (import ./_mixins/linux-builder { inherit lib ci; })
      ./_mixins/nix-gc
      ./_mixins/sudo
    ]
    ++ lib.optionals (!isWork) [
      ./_mixins/browser
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

  networking = lib.optionalAttrs (!isWork) {
    knownNetworkServices = [
      "Ethernet"
      "Wi-Fi"
    ];
    dhcpClientId = hostname;
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
