{ config, lib, ... }:
{
  virtualisation.vmVariant = {
    virtualisation = {
      # nix-darwin requires this account before activation. Drop once
      # nix-darwin-vm defaults to the primary user itself.
      bootstrapUser = config.system.primaryUser;
      diskSize = 100 * 1024;
      graphics = lib.mkDefault false;
    };

    # Local configuration tests do not need to start another VM for Linux builds.
    nix.linux-builder.enable = lib.mkForce false;

    # Match nix-darwin-vm#9 until the input includes passwordless bootstrap sudo.
    security.sudo.extraConfig = ''
      ${config.system.primaryUser} ALL=(ALL) NOPASSWD: ALL
    '';

    # The guest disk is smaller than the physical hosts' GC thresholds.
    nix.settings = {
      min-free = 4 * 1024 * 1024 * 1024;
      max-free = 8 * 1024 * 1024 * 1024;
    };
  };
}
