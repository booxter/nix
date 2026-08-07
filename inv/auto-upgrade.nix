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
  phases = {
    builder.upgrade = weekly "Mon" maintenanceWindow.start;
    cache.upgrade = weekly "Mon" (clock 4 0);
    hypervisor.upgrade = weekly "Mon" (clock 4 30);
    workload.upgrade = daily (clock 6 0);
  };
  weeklyReboot = weekly "Sat" (clock 5 30);
  infrastructureSchedules = [
    phases.builder.upgrade
    phases.cache.upgrade
    phases.hypervisor.upgrade
  ];
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
    schedule: schedule.cadence == "weekly" && schedule.weekday == phases.hypervisor.upgrade.weekday
  ) infrastructureSchedules;
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
assert lib.asserts.assertMsg (
  clockMinutes weeklyReboot.at + slotDurationMinutes <= clockMinutes phases.workload.upgrade.at
) "the deferred weekly reboot must complete before the workload upgrade phase";
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
