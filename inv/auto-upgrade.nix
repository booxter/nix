{ lib }:
let
  clock = hour: minute: { inherit hour minute; };
  clockMinutes = value: value.hour * 60 + value.minute;
  clockFromMinutes = value: clock (builtins.div value 60) (lib.mod value 60);
  daily = at: {
    cadence = "daily";
    inherit at;
  };
  weekly = weekday: at: {
    cadence = "weekly";
    inherit at weekday;
  };
  slotDurationMinutes = 30;
  maintenanceWindow = {
    start = clock 3 30;
    end = clock 6 30;
  };
  rebootWindowFor = start: {
    lower = start;
    upper = clockFromMinutes (clockMinutes start + slotDurationMinutes);
  };
  validClock = value: value.hour >= 0 && value.hour < 24 && value.minute >= 0 && value.minute < 60;
  formatClock =
    value:
    let
      pad = part: if part < 10 then "0${toString part}" else toString part;
    in
    "${pad value.hour}:${pad value.minute}";
  renderSchedule =
    schedule:
    lib.optionalString (schedule.cadence == "weekly") "${schedule.weekday} " + formatClock schedule.at;
  renderRebootWindow = window: {
    lower = formatClock window.lower;
    upper = formatClock window.upper;
  };
  hypervisorAtByRealm = {
    home = {
      prx1-lab = clock 4 30;
      prx2-lab = clock 5 0;
      prx3-lab = clock 5 30;
    };
    work.nvws = clock 4 30;
  };
  hypervisorAtByHost = lib.mergeAttrsList (builtins.attrValues hypervisorAtByRealm);
  phases = {
    builder.upgrade = weekly "Mon" maintenanceWindow.start;
    cache.upgrade = weekly "Mon" (clock 4 0);
    hypervisor = {
      cadence = "weekly";
      weekday = "Mon";
      atByHost = hypervisorAtByHost;
    };
    workload.upgrade = daily (clock 6 0);
  };
  weeklyReboot = weekly "Sat" (clock 5 30);
  infrastructureSchedules = [
    phases.builder.upgrade
    phases.cache.upgrade
  ]
  ++ map (weekly phases.hypervisor.weekday) (builtins.attrValues hypervisorAtByHost);
  infrastructureStarts = map (schedule: schedule.at) infrastructureSchedules;
  maintenanceStarts = infrastructureStarts ++ [ phases.workload.upgrade.at ];
  orderedSlots = lib.unique (
    lib.sort (left: right: clockMinutes left < clockMinutes right) maintenanceStarts
  );
  slotsDoNotOverlap =
    starts:
    if builtins.length starts < 2 then
      true
    else
      clockMinutes (builtins.head starts) + slotDurationMinutes
      <= clockMinutes (builtins.head (builtins.tail starts))
      && slotsDoNotOverlap (builtins.tail starts);
  startsFitMaintenanceWindow = lib.all (
    start:
    clockMinutes start >= clockMinutes maintenanceWindow.start
    && clockMinutes start + slotDurationMinutes <= clockMinutes maintenanceWindow.end
  ) (maintenanceStarts ++ [ weeklyReboot.at ]);
  infrastructureCadenceIsWeekly = lib.all (
    schedule: schedule.cadence == "weekly" && schedule.weekday == phases.hypervisor.weekday
  ) infrastructureSchedules;
  hypervisorSlotsDoNotOverlap = lib.all (
    realmSlots:
    let
      starts = builtins.attrValues realmSlots;
      ordered = lib.sort (left: right: clockMinutes left < clockMinutes right) starts;
    in
    builtins.length starts == builtins.length (lib.unique (map clockMinutes starts))
    && slotsDoNotOverlap ordered
  ) (builtins.attrValues hypervisorAtByRealm);
  hypervisorNames = builtins.concatMap builtins.attrNames (builtins.attrValues hypervisorAtByRealm);
in
assert lib.asserts.assertMsg (lib.all validClock (
  maintenanceStarts
  ++ [
    maintenanceWindow.start
    maintenanceWindow.end
    weeklyReboot.at
  ]
)) "auto-upgrade policy contains an invalid clock time";
assert lib.asserts.assertMsg infrastructureCadenceIsWeekly
  "all build-infrastructure maintenance must use the weekly hypervisor weekday";
assert lib.asserts.assertMsg (
  phases.workload.upgrade.cadence == "daily"
) "workload auto-upgrades must remain daily";
assert lib.asserts.assertMsg startsFitMaintenanceWindow
  "all auto-upgrade and reboot slots must fit inside the 03:30-06:30 maintenance window";
assert lib.asserts.assertMsg (slotsDoNotOverlap orderedSlots)
  "auto-upgrade maintenance slots must not overlap";
assert lib.asserts.assertMsg hypervisorSlotsDoNotOverlap
  "hypervisor maintenance slots must not overlap within a realm";
assert lib.asserts.assertMsg (
  clockMinutes weeklyReboot.at + slotDurationMinutes <= clockMinutes phases.workload.upgrade.at
) "the deferred weekly reboot must complete before the workload upgrade phase";
assert lib.asserts.assertMsg (
  builtins.length hypervisorNames == builtins.length (lib.unique hypervisorNames)
) "each hypervisor must have exactly one maintenance slot";
{
  inherit
    maintenanceWindow
    phases
    rebootWindowFor
    renderRebootWindow
    renderSchedule
    slotDurationMinutes
    weeklyReboot
    ;
  randomizedDelaySec = "0min";
  persistent = false;
  holds = [ ];
}
