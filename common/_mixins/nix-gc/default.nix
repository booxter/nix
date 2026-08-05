{
  config,
  hostInventory,
  hostname,
  lib,
  ...
}:
let
  GiB = 1024 * 1024 * 1024;
  vmDiskSizeGiB = hostInventory.nixosHostSpecsByName.${hostname}.diskSize or 100;
  # VM disks can be much smaller than physical hosts. Start GC at 20%
  # free and target 40%, capped at the physical-host thresholds.
  minFreeGiB = if config.host.isVM then lib.min 40 (builtins.div vmDiskSizeGiB 5) else 40;
  maxFreeGiB = 2 * minFreeGiB;
in
{
  nix.gc = {
    automatic = true;
    options = "--delete-older-than 1d";
  };
  nix.settings = {
    gc-reserved-space = GiB;
    keep-derivations = false;
    min-free = minFreeGiB * GiB;
    max-free = maxFreeGiB * GiB;
  };
  # then optimise the nix store an hour later
  nix.optimise.automatic = true;
}
