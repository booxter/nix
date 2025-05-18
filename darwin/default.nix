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
    ./_mixins/community-builders
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
    max-jobs = 4;

    # flox config
    substituters = [
      "https://cache.flox.dev"
    ];
    trusted-public-keys = [
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
    ];

    trusted-users = [ "@admin" ];
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  system.primaryUser = "ihrachys";

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true;

  # TODO: is it still needed? Does it operate in the user context? (Not root?)
  system.activationScripts.userActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
