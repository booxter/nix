{ lib }:
let
  clock = hour: minute: { inherit hour minute; };
  daily = at: {
    cadence = "daily";
    inherit at;
  };
  weekly = weekday: at: {
    cadence = "weekly";
    inherit at weekday;
  };
  randomizedDelayMinutes = 5;
  minimumInfrastructureBufferMinutes = 20;
  night = {
    start = clock 0 0;
    end = clock 6 0;
  };
  clockMinutes = clock: clock.hour * 60 + clock.minute;
  validClock = clock: clock.hour >= 0 && clock.hour < 24 && clock.minute >= 0 && clock.minute < 60;
  formatClock =
    clock:
    let
      pad = value: if value < 10 then "0${toString value}" else toString value;
    in
    "${pad clock.hour}:${pad clock.minute}";
  renderSchedule =
    schedule:
    lib.optionalString (schedule.cadence == "weekly") "${schedule.weekday} " + formatClock schedule.at;
  renderRebootWindow = window: {
    lower = formatClock window.lower;
    upper = formatClock window.upper;
  };
  workloadRebootWindow = {
    lower = clock 4 0;
    upper = night.end;
  };
  phases = {
    workload = {
      upgrade = daily (clock 5 15);
      rebootWindow = workloadRebootWindow;
    };

    builder = {
      upgrade = weekly "Mon" (clock 3 0);
      rebootWindow = {
        lower = clock 2 59;
        upper = night.end;
      };
    };

    cache = {
      upgrade = weekly "Mon" (clock 3 30);
      rebootWindow = {
        lower = clock 2 59;
        upper = night.end;
      };
    };

    hypervisor = {
      cadence = "weekly";
      weekday = "Mon";
      atByHost = {
        prx1-lab = clock 3 50;
        nvws = clock 4 0;
        prx2-lab = clock 4 20;
        prx3-lab = clock 4 50;
      };
      rebootWindow = {
        lower = clock 3 45;
        upper = night.end;
      };
    };
  };
  weeklyReboot = weekly "Sat" (clock 4 0);
  infrastructureSchedules = [
    phases.builder.upgrade
    phases.cache.upgrade
  ]
  ++ map (weekly phases.hypervisor.weekday) (builtins.attrValues phases.hypervisor.atByHost);
  infrastructureStarts = map (schedule: schedule.at) infrastructureSchedules;
  orderedStarts = lib.sort (left: right: clockMinutes left < clockMinutes right) (
    infrastructureStarts ++ [ phases.workload.upgrade.at ]
  );
  startWindowsDoNotOverlap =
    clocks:
    if builtins.length clocks < 2 then
      true
    else
      clockMinutes (builtins.head clocks) + randomizedDelayMinutes
      < clockMinutes (builtins.head (builtins.tail clocks))
      && startWindowsDoNotOverlap (builtins.tail clocks);
  latestInfrastructureStart = lib.foldl' lib.max 0 (map clockMinutes infrastructureStarts);
  allStarts = infrastructureStarts ++ [
    phases.workload.upgrade.at
    weeklyReboot.at
  ];
  rebootWindows =
    map (phase: phase.rebootWindow) (builtins.attrValues (builtins.removeAttrs phases [ "hypervisor" ]))
    ++ [ phases.hypervisor.rebootWindow ];
  allRebootClocks = builtins.concatMap (window: [
    window.lower
    window.upper
  ]) rebootWindows;
  infrastructureCadenceIsWeekly = lib.all (
    schedule: schedule.cadence == "weekly" && schedule.weekday == phases.hypervisor.weekday
  ) infrastructureSchedules;
  startsAreAtNight = lib.all (
    clock:
    clockMinutes clock >= clockMinutes night.start
    && clockMinutes clock + randomizedDelayMinutes <= clockMinutes night.end
  ) allStarts;
  rebootWindowsAreAtNight = lib.all (
    clock:
    clockMinutes clock >= clockMinutes night.start && clockMinutes clock <= clockMinutes night.end
  ) allRebootClocks;
  rebootWindowsAreOrdered = lib.all (
    window: clockMinutes window.lower < clockMinutes window.upper
  ) rebootWindows;
in
assert lib.asserts.assertMsg (lib.all validClock (
  allStarts ++ allRebootClocks
)) "auto-upgrade policy contains an invalid clock time";
assert lib.asserts.assertMsg infrastructureCadenceIsWeekly
  "all build-infrastructure maintenance must use the weekly hypervisor weekday";
assert lib.asserts.assertMsg (
  phases.workload.upgrade.cadence == "daily"
) "workload auto-upgrades must remain daily";
assert lib.asserts.assertMsg startsAreAtNight
  "all auto-upgrade starts, including random delay, must remain inside the night window";
assert lib.asserts.assertMsg rebootWindowsAreAtNight
  "all auto-upgrade reboot windows must remain inside the night window";
assert lib.asserts.assertMsg rebootWindowsAreOrdered
  "auto-upgrade reboot windows must end after they begin";
assert lib.asserts.assertMsg (startWindowsDoNotOverlap orderedStarts)
  "auto-upgrade randomized start ranges must not overlap";
assert lib.asserts.assertMsg
  (
    clockMinutes phases.workload.upgrade.at - (latestInfrastructureStart + randomizedDelayMinutes)
    >= minimumInfrastructureBufferMinutes
  )
  "workload upgrades must start at least ${toString minimumInfrastructureBufferMinutes} minutes after the infrastructure launch range";
{
  inherit
    formatClock
    minimumInfrastructureBufferMinutes
    night
    phases
    renderRebootWindow
    renderSchedule
    weeklyReboot
    ;
  randomizedDelaySec = "${toString randomizedDelayMinutes}min";
  persistent = false;

  holds = [ ];
}
