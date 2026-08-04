{
  config,
  hostInventory,
  hostSpecName,
  lib,
  ...
}:
let
  resourceControl = import ../../lib/systemd-resource-control.nix { inherit lib; };
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};
  inventory = hostSpec.resourceControl or { };
  diskSwapGiB = inventory.diskSwapGiB or null;
  settingsByService = resourceControl.compile (inventory.systemServices or { });
  unknownServices = lib.filter (
    name:
    builtins.removeAttrs config.systemd.services.${name}.serviceConfig (
      lib.attrNames settingsByService.${name}
    ) == { }
  ) (lib.attrNames settingsByService);
in
{
  zramSwap = {
    enable = true;
    memoryPercent = 25;
    memoryMax = (if config.host.isProxmox then 4 else 16) * 1024 * 1024 * 1024;
    priority = 100;
  };

  swapDevices = lib.optional (diskSwapGiB != null) {
    device = "/var/lib/swapfile";
    size = diskSwapGiB * 1024;
    priority = 0;
  };

  systemd.oomd = {
    enable = true;
    enableRootSlice = !config.host.isProxmox;
    enableUserSlices = true;
  };

  systemd.slices = {
    user.sliceConfig = {
      MemoryHigh = "65%";
      MemoryMax = "75%";
    };
    background.sliceConfig = {
      CPUWeight = 10;
      IOWeight = 10;
      MemoryHigh = "50%";
      MemoryMax = "70%";
    };
  };

  assertions = [
    {
      assertion = diskSwapGiB == null || (builtins.isInt diskSwapGiB && diskSwapGiB > 0);
      message = "resourceControl.diskSwapGiB must be a positive integer";
    }
    {
      assertion = diskSwapGiB == null || !config.host.isProxmox;
      message = "Proxmox hosts must not use disk-backed swap";
    }
    {
      assertion = unknownServices == [ ];
      message = "Resource policy references unknown system services: ${lib.concatStringsSep ", " unknownServices}";
    }
  ];

  systemd.services = lib.mapAttrs (_: settings: {
    serviceConfig = lib.mapAttrs (_: lib.mkOverride 900) settings;
  }) settingsByService;
}
