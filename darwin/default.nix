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
  imports = [
    # TODO: gracefully handle missing per-machine config
    ./${hostname}
    ./_mixins/defaults
    ./_mixins/fonts
    ./_mixins/gnupg
    ./_mixins/homebrew
    ./_mixins/linux-builder
    ./_mixins/nix-gc
    ./_mixins/sudo
  ]
  ++ lib.optionals (!isWork) [
    ./_mixins/browser
    ./_mixins/community-builders
    ./_mixins/remote-builders
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

  networking = {
    knownNetworkServices = [ "Wi-Fi" ];
    dhcpClientId = hostname;
  };

  system = {
    activationScripts.postActivation.text = ''
      echo "Do not sleep when on AC power."
      pmset -c sleep 0 # Needs testing - UI not immediately updated.
    '';
  };

  # TODO: is it still needed? Does it operate in the user context? (Not root?)
  system.activationScripts.userActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
