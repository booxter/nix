{ lib, ... }:
{
  virtualisation.vmVariant = {
    virtualisation = {
      diskSize = 100 * 1024;
      graphics = lib.mkDefault false;
    };

    # Local configuration tests do not need to start another VM for Linux builds.
    nix.linux-builder.enable = lib.mkForce false;

    # The guest disk is smaller than the physical hosts' GC thresholds.
    nix.settings = {
      min-free = 4 * 1024 * 1024 * 1024;
      max-free = 8 * 1024 * 1024 * 1024;
    };
  };
}
