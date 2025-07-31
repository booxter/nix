{
  hostname,
  lib,
  username,
  platform,
  stateVersion,
  isWork,
  ...
}: {
  imports = [
    ./${hostname}
    ./_mixins/defaults
    ./_mixins/desktop
    ./_mixins/fonts
    ./_mixins/gnupg
    ./_mixins/homebrew
    ./_mixins/linux-builder
    ./_mixins/nix-gc
    ./_mixins/sudo
  ] ++ lib.optionals (!isWork) [
    ./_mixins/browser
    ./_mixins/community-builders
  ];

  nixpkgs.hostPlatform = lib.mkDefault platform;

  programs.ssh = lib.optionalAttrs isWork {
    extraConfig = ''
      Host nVM
        Hostname localhost
        IdentityFile /Users/${username}/.ssh/id_ed25519
        Port 11110
        User ${username}
    '';
  };

  system.stateVersion = stateVersion;

  system.primaryUser = "ihrachyshka";

  users.users.${username}.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILF2Ga7NLRUkAqv6B4GDya40U1mQalWo8XOhEhOPF3zW ihrachyshka@Mac.lan"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHt25mSiJLQjx2JECMuhTZEV6rlrOYk3CT2cUEdXAoYs ihrachyshka@ihrachyshka-mlt"
  ];

  # Create /etc/zshrc that loads the nix-darwin environment.
  programs.zsh.enable = true;

  # TODO: is it still needed? Does it operate in the user context? (Not root?)
  system.activationScripts.userActivation.text = ''
    # Following line should allow us to avoid a logout/login cycle
    /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
  '';
}
