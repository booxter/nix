{
  config,
  hostname,
  inputs,
  lib,
  outputs,
  pkgs,
  platform,
  username,
  ...
}: {
  imports = [
    ./${hostname}
    ./_mixins/browser
    ./_mixins/defaults
    ./_mixins/desktop
    ./_mixins/fonts
    ./_mixins/gnupg
    ./_mixins/homebrew
    ./_mixins/iterm2
    ./_mixins/kinit-pass
    # ./_mixins/linux-builder
    ./_mixins/nix-gc
    ./_mixins/rosetta-builder
    ./_mixins/sudo
  ];

  nixpkgs = {
    hostPlatform = lib.mkDefault "${platform}";
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
      outputs.overlays.unstable-packages
      outputs.overlays.master-packages
    ];
    config = {
      allowUnfree = true;
    };
  };

  # Auto upgrade nix package.
  nix.package = pkgs.nix;

  nix.settings = {
    # Necessary for using flakes on this system.
    experimental-features = "nix-command flakes";

    # Some packages like firefox can kill the machine due to memory pressure
    max-jobs = 2;

    # flox config
    substituters = [
      "https://cache.flox.dev"
    ];
    trusted-public-keys = [
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
    ];

    trusted-users = [ "@admin" ];
  };

  # Avoid wait4path and sh to reduce the scope of Full Disk Access for nix-daemon.
  launchd.daemons.nix-daemon.serviceConfig = let
    command = "/run/current-system/sw/bin/nix-daemon";
  in {
    KeepAlive = lib.mkForce {
      PathState = {
        "${toString command}" = true;
      };
    };
    ProgramArguments = lib.mkForce [
      "${command}"
    ];
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true;

  system.activationScripts.postUserActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
