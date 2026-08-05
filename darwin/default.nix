{
  config,
  hostInventory,
  hostSpec,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  hostname = hostSpec.name;
  username = hostSpec.username;
in
{
  imports = [
    inputs.nix-homebrew.darwinModules.nix-homebrew
    inputs.sops-nix.darwinModules.sops
    inputs.stylix.darwinModules.stylix
    ../common
    inputs.home-manager.darwinModules.home-manager
  ]
  ++ lib.optionals (builtins.pathExists ./${hostname}) [
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
    ./_mixins/nix-store
    ./_mixins/observability-client
    ./_mixins/remote-gui
    ./_mixins/sketchybar-alertmanager
    ./_mixins/sketchybar-jellyfin
    ./_mixins/sudo
    ./_mixins/thermal-accounting
    ./_mixins/xquartz
    ./_mixins/attic
    ./_mixins/browser
    ./_mixins/vnc
    ./_mixins/vnc-open
  ]
  ++ lib.optionals (hostname == "mair") [
    ./_mixins/secretive
  ];

  system.stateVersion = hostSpec.stateVersion;
  home-manager = {
    extraSpecialArgs = {
      inherit
        hostInventory
        hostSpec
        inputs
        ;
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${username} = ../hm;
  };

  host.remoteGui.x11.enable = lib.mkDefault (!config.host.isWork && config.host.isDesktop);

  system.primaryUser = username;

  users.users.${username} = {
    home = "/Users/${username}";
    createHome = true;
    description = "Ihar Hrachyshka";
    shell = pkgs.zsh;
  };

  system.defaults.smb = lib.optionalAttrs (!config.host.isWork) {
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
