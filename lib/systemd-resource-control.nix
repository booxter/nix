{ lib }:
let
  classes = {
    lightweight = {
      Slice = "background.slice";
      MemoryHigh = "512M";
      MemoryMax = "1G";
      TasksMax = 128;
    };
    medium = {
      Slice = "background.slice";
      MemoryHigh = "2G";
      MemoryMax = "4G";
      TasksMax = 512;
    };
    critical = {
      ManagedOOMPreference = "avoid";
    };
  };
  heavySettings =
    {
      memoryHigh,
      memoryMax,
      cpuQuota ? null,
      memoryLow ? null,
      slice ? null,
      tasksMax ? null,
      timeoutStartSec ? null,
    }:
    lib.filterAttrs (_: value: value != null) {
      CPUQuota = cpuQuota;
      MemoryHigh = memoryHigh;
      MemoryLow = memoryLow;
      MemoryMax = memoryMax;
      Slice = slice;
      TasksMax = tasksMax;
      TimeoutStartSec = timeoutStartSec;
    };
in
{
  compile =
    scope:
    let
      heavy = scope.heavy or { };
      fixed = builtins.removeAttrs scope [ "heavy" ];
      names = lib.concatLists (lib.attrValues fixed) ++ lib.attrNames heavy;
    in
    assert lib.assertMsg (
      lib.length names == lib.length (lib.unique names)
    ) "a systemd service has multiple resource classes";
    assert lib.assertMsg (lib.all (
      name: !lib.hasSuffix ".service" name
    ) names) "resource-control service names must omit the .service suffix";
    lib.concatMapAttrs (class: services: lib.genAttrs services (_: classes.${class})) fixed
    // lib.mapAttrs (_: heavySettings) heavy;
}
