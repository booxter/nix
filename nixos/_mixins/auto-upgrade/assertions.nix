{
  config,
  lib,
  outputs,
  ...
}:
let
  maintenanceLib = import ./lib.nix { inherit lib; };
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  reboot = config.host.autoUpgrade.reboot;
  policy = config.host.autoUpgrade.policy;
  windowStart = maintenanceLib.clockMinutes policy.allowedWindow.start;
  windowEnd = maintenanceLib.clockMinutes policy.allowedWindow.end;
  latestStart = windowEnd - policy.slotDurationMinutes - policy.randomizedDelayMinutes;
in
{
  assertions = [
    {
      assertion = reboot.mode != "scheduled" || reboot.calendar != null;
      message = "host.autoUpgrade.reboot.calendar must be set when reboot.mode is `scheduled`.";
    }
    {
      assertion = windowStart < windowEnd;
      message = "host.autoUpgrade.policy.allowedWindow must end after it starts.";
    }
    {
      assertion = latestStart >= windowStart;
      message = "host.autoUpgrade policy slot duration must fit inside the allowed window.";
    }
    {
      assertion =
        lib.all
          (
            clock:
            let
              minutes = maintenanceLib.clockMinutes clock;
            in
            minutes >= windowStart && minutes <= latestStart
          )
          [
            policy.dailyAt
            policy.deferredRebootAt
          ];
      message = "preferred auto-upgrade times must fit inside the allowed maintenance window.";
    }
    {
      assertion = model.policyMismatches == [ ];
      message = "hosts in one realm must use the same auto-upgrade policy; mismatches: ${lib.concatStringsSep ", " model.policyMismatches}";
    }
    {
      assertion = model.unknownExclusionHosts == [ ];
      message = "auto-upgrade exclusions name unknown hosts: ${lib.concatStringsSep ", " model.unknownExclusionHosts}";
    }
    {
      assertion = model.weekdayConflicts == [ ];
      message = lib.concatStringsSep "; " model.weekdayConflicts;
    }
    {
      assertion = model.failures == [ ];
      message = lib.concatStringsSep "; " model.failures;
    }
  ];
}
