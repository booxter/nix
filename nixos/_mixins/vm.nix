{
  config,
  hostSpec,
  inputs,
  lib,
  modulesPath,
  system,
  ...
}:
let
  username = config.host.username;
  isVM = hostSpec.isVM or false;
  cores = hostSpec.cores or 4;
  memorySize = hostSpec.memorySize or 8;
  diskSize = hostSpec.diskSize or 100;
  virtPlatform = hostSpec.virtPlatform or system;
  GiB = 1024 * 1024 * 1024;
  # VM disks can be much smaller than physical hosts. Start GC at 20%
  # free and target 40%, capped at the physical-host thresholds.
  minFreeGiB = lib.min 40 (builtins.div diskSize 5);
in
{
  imports = lib.optionals isVM [ (modulesPath + "/profiles/qemu-guest.nix") ];

  config = lib.mkIf config.host.isVM {
    nix.settings = {
      min-free = minFreeGiB * GiB;
      max-free = 2 * minFreeGiB * GiB;
    };

    services.getty.autologinUser = username;
    services.qemuGuest.enable = true;

    virtualisation.vmVariant.virtualisation = {
      host.pkgs = inputs.nixpkgs.legacyPackages.${virtPlatform};
      graphics = false;
      # Limit cores to avoid overloading the local host.
      cores = inputs.nixpkgs.lib.min cores 8;
      memorySize = memorySize * 1024;
      diskSize = diskSize * 1024;
    };
  };
}
