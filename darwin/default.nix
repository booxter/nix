{
  config,
  facts,
  hostSpec,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  hostname = hostSpec.name;
  username = config.host.username;
in
{
  imports = [
    inputs.nix-homebrew.darwinModules.nix-homebrew
    inputs.sops-nix.darwinModules.sops
    inputs.stylix.darwinModules.stylix
    ../common
    inputs.home-manager.darwinModules.home-manager
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
    ./_mixins/nix
    ./_mixins/observability
    ./_mixins/secretive
    ./_mixins/sketchybar-alertmanager
    ./_mixins/sketchybar-jellyfin
    ./_mixins/sketchybar-network
    ./_mixins/sudo
    ./_mixins/thermal-accounting
    ./_mixins/ups-client
    ./_mixins/xquartz
    ./_mixins/yubi.nix
    ./_mixins/attic
    ./_mixins/browser
  ];

  home-manager = {
    extraSpecialArgs = {
      inherit
        facts
        hostSpec
        inputs
        ;
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${username} = {
      imports = [ ../hm ];
      home.stateVersion = "25.11";
    };
  };

  system.primaryUser = username;

  users.users.${username} = {
    home = "/Users/${username}";
    createHome = true;
    description = "Ihar Hrachyshka";
    shell = pkgs.zsh;
  };

  system.defaults.smb = lib.optionalAttrs config.host.management.manageNetworkIdentity {
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
