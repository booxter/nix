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

  # This is not working; need to figure out how to make it work
  #nix.buildMachines = let
  #  makeMachine = args: args // {
  #    sshUser = "booxter";
  #    sshKey = "/Users/ihrachys/.ssh/id_ed25519";
  #    protocol = "ssh-ng";
  #  };
  #in [
  #  (makeMachine {
  #    hostName = "aarch64-build-box.nix-community.org";
  #    publicHostKey = "AAAAC3NzaC1lZDI1NTE5AAAAIG9uyfhyli+BRtk64y+niqtb+sKquRGGZ87f4YRc8EE1";
  #    system = "aarch64-linux";
  #  })
  #  (makeMachine {
  #    hostName = "build-box.nix-community.org";
  #    publicHostKey = "AAAAC3NzaC1lZDI1NTE5AAAAIElIQ54qAy7Dh63rBudYKdbzJHrrbrrMXLYl7Pkmk88H";
  #    system = "x86_64-linux";
  #  })
  #];

  #programs.ssh.knownHosts = {
  #  "aarch64-build-box.nix-community.org" = {
  #    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG9uyfhyli+BRtk64y+niqtb+sKquRGGZ87f4YRc8EE1";
  #  };
  #  "build-box.nix-community.org" = {
  #    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIElIQ54qAy7Dh63rBudYKdbzJHrrbrrMXLYl7Pkmk88H";
  #  };
  #};

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
