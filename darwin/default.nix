{
  config,
  fleetInventory,
  inputs,
  sshKeys,
  lib,
  pkgs,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  userEnvironmentTier = fleetInventory.hosts.${hostname}.userEnvironmentTier;
in
{
  imports = [
    inputs.nix-homebrew.darwinModules.nix-homebrew
    inputs.nix-index-database.darwinModules.nix-index
    inputs.sops-nix.darwinModules.sops
    inputs.stylix.darwinModules.stylix
    ../common
    inputs.home-manager.darwinModules.home-manager
  ]
  ++ [
    ./_mixins/defaults
    ./_mixins/docker-desktop
    ./_mixins/etc
    ./_mixins/fonts
    ./_mixins/hardware
    ./_mixins/homebrew
    ./_mixins/internal-pki
    ./_mixins/lan-wan-accounting
    ./_mixins/launchd
    ./_mixins/logs-client
    ./_mixins/networking
    ./_mixins/nix
    ./_mixins/observability
    ./_mixins/remote-control
    ./_mixins/security
    ./_mixins/sketchybar-alertmanager
    ./_mixins/sketchybar-jellyfin
    ./_mixins/sketchybar-network
    ./_mixins/ssh
    ./_mixins/thermal-accounting
    ./_mixins/tmpfiles
    ./_mixins/ups-client
    ./_mixins/browser
  ];

  home-manager = {
    extraSpecialArgs = { inherit inputs sshKeys fleetInventory; };
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${username} = {
      imports = [ ../hm ] ++ lib.optional (userEnvironmentTier != "base") ../hm/_mixins/vim;
      host.hm.env.tier = userEnvironmentTier;
      home.stateVersion = "25.11";
    };
  };

  # GTK needs icon themes from the Home Manager user profiles at runtime.
  environment.pathsToLink = [ "/share/icons" ];

  system.primaryUser = username;

  host.nix.rosetta.acceptLicense = true;

  users.users.${username} = {
    home = "/Users/${username}";
    createHome = true;
    description = "Ihar Hrachyshka";
    shell = pkgs.zsh;
  };

  # nix-darwin only updates shells for knownUsers, which must not include the
  # primary admin account. Apple zsh can miss Nix terminfo during SSH startup.
  # TODO: upstream an option to manage an existing primary user's shell alone.
  system.activationScripts.users.text = lib.mkAfter ''
    echo >&2 "setting login shell for ${username}..."
    /usr/bin/dscl . -read ${lib.escapeShellArg "/Users/${username}"} UniqueID >/dev/null
    /usr/bin/dscl . -create ${lib.escapeShellArg "/Users/${username}"} UserShell /run/current-system/sw${pkgs.zsh.shellPath}
  '';

  system.defaults.smb = lib.optionalAttrs config.host.management.manageNetworkIdentity {
    NetBIOSName = hostname;
    ServerDescription = hostname;
  };

  system.activationScripts.postActivation.text = ''
    echo "Do not idle sleep or hibernate when on AC power."
    pmset -c sleep 0 disksleep 0 standby 0 powernap 0 hibernatemode 0

    echo "Prefer network over sleep."
    pmset networkoversleep 1
  '';

  launchd.daemons.prevent-ac-sleep = {
    command = "/usr/bin/caffeinate -s";
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      StandardOutPath = "/var/log/nix-darwin/prevent-ac-sleep.log";
      StandardErrorPath = "/var/log/nix-darwin/prevent-ac-sleep.log";
    };
  };

  # TODO: is it still needed? Does it operate in the user context? (Not root?)
  system.activationScripts.userActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
