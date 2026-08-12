{
  config,
  lib,
  outputs,
}:
let
  maintenanceLib = import ./lib.nix { inherit lib; };
  inherit (maintenanceLib)
    clockMinutes
    moreRestrictiveCadence
    renderSchedule
    ;
  localHost = config.networking.hostName;
  localPolicy = config.host.autoUpgrade.policy;
  hostView = hostConfig: {
    inherit (hostConfig.host) realm;
    inherit (hostConfig.host.autoUpgrade) claims policy;
  };
  configurations = removeAttrs outputs.nixosConfigurations [ localHost ];
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) configurations // {
    ${localHost} = hostView config;
  };
  hostNames = builtins.attrNames hosts;
  allWeekdays = [
    "Mon"
    "Tue"
    "Wed"
    "Thu"
    "Fri"
    "Sat"
    "Sun"
  ];
  policyHosts = lib.filterAttrs (_: host: host.realm == config.host.realm) hosts;
  policyMismatches = builtins.attrNames (
    lib.filterAttrs (_: host: host.policy != localPolicy) policyHosts
  );
  claimsFor = hostName: builtins.attrValues hosts.${hostName}.claims;
  operationPolicy =
    hostName: operation:
    let
      claims = claimsFor hostName;
      cadences = map (claim: claim.${operation}.cadence) (
        builtins.filter (claim: claim.${operation}.cadence != null) claims
      );
      requestedWeekdays = lib.unique (
        map (claim: claim.${operation}.weekday) (
          builtins.filter (claim: claim.${operation}.weekday != null) claims
        )
      );
      cadence = lib.foldl' moreRestrictiveCadence "daily" cadences;
      weekday =
        if cadence != "weekly" then
          null
        else if requestedWeekdays != [ ] then
          builtins.head requestedWeekdays
        else
          null;
    in
    {
      weekdays = requestedWeekdays;
      inherit cadence weekday;
      availabilityGroups = lib.unique (builtins.concatMap (claim: claim.availabilityGroups) claims);
      exclusions = builtins.concatMap (claim: builtins.attrValues claim.exclusions) claims;
    };
  policies = lib.genAttrs hostNames (hostName: {
    switch = operationPolicy hostName "switch";
    reboot = operationPolicy hostName "reboot";
  });
  weekdayConflicts = builtins.concatMap (
    hostName:
    builtins.concatMap
      (
        operation:
        lib.optional (builtins.length policies.${hostName}.${operation}.weekdays > 1) (
          "${hostName}.${operation} requests incompatible weekly maintenance days"
        )
      )
      [
        "switch"
        "reboot"
      ]
  ) hostNames;
  unknownExclusionHosts = lib.unique (
    builtins.concatMap (
      hostName:
      builtins.concatMap
        (
          operation:
          builtins.concatMap (
            exclusion: builtins.filter (target: !builtins.elem target hostNames) exclusion.hosts
          ) policies.${hostName}.${operation}.exclusions
        )
        [
          "switch"
          "reboot"
        ]
    ) hostNames
  );
  sharesAvailabilityGroup =
    left: right: operation:
    lib.intersectLists policies.${left}.${operation}.availabilityGroups
      policies.${right}.${operation}.availabilityGroups != [ ];
  exclusionBetween =
    left: right: operation:
    let
      matching = builtins.filter (
        exclusion:
        builtins.elem operation exclusion.operations
        && (builtins.elem right exclusion.hosts || builtins.elem left exclusion.hosts)
      ) (policies.${left}.${operation}.exclusions ++ policies.${right}.${operation}.exclusions);
    in
    {
      conflicts = matching != [ ];
      minimumGapMinutes = lib.foldl' lib.max 0 (map (exclusion: exclusion.minimumGapMinutes) matching);
    };
  conflicts =
    left: right: operation:
    sharesAvailabilityGroup left right operation || (exclusionBetween left right operation).conflicts;
  schedulesShareDay =
    left: right: left.cadence == "daily" || right.cadence == "daily" || left.weekday == right.weekday;
  schedulesOverlap =
    left: right: gap:
    schedulesShareDay left right
    && !(
      left.start + localPolicy.slotDurationMinutes + localPolicy.randomizedDelayMinutes + gap
      <= right.start
      ||
        right.start + localPolicy.slotDurationMinutes + localPolicy.randomizedDelayMinutes + gap
        <= left.start
    );
  windowStart = clockMinutes localPolicy.allowedWindow.start;
  windowEnd = clockMinutes localPolicy.allowedWindow.end;
  latestStart = windowEnd - localPolicy.slotDurationMinutes - localPolicy.randomizedDelayMinutes;
  slotCount =
    if latestStart < windowStart then
      0
    else
      builtins.div (latestStart - windowStart) localPolicy.slotStepMinutes;
  candidateStarts = map (index: windowStart + index * localPolicy.slotStepMinutes) (
    lib.range 0 slotCount
  );
  preferredStart =
    operation: operationConfig: weekday:
    if operationConfig.cadence == "daily" then
      clockMinutes localPolicy.dailyAt
    else if operation == "reboot" && weekday != localPolicy.preferredWeeklyDay then
      clockMinutes localPolicy.deferredRebootAt
    else
      windowStart;
  orderedStarts =
    operation: operationConfig: weekday:
    if operationConfig.cadence == "weekly" && weekday == localPolicy.preferredWeeklyDay then
      candidateStarts
    else
      let
        preferred = preferredStart operation operationConfig weekday;
        distance = value: if value < preferred then preferred - value else value - preferred;
        candidates = lib.unique (
          candidateStarts ++ lib.optional (preferred >= windowStart && preferred <= latestStart) preferred
        );
      in
      builtins.sort (
        left: right: distance left < distance right || (distance left == distance right && left < right)
      ) candidates;
  candidateWeekdays =
    operationConfig:
    if operationConfig.cadence != "weekly" then
      [ null ]
    else if operationConfig.weekday != null then
      [ operationConfig.weekday ]
    else
      [ localPolicy.preferredWeeklyDay ]
      ++ builtins.filter (weekday: weekday != localPolicy.preferredWeeklyDay) allWeekdays;
  scheduleCandidates =
    operation: operationConfig:
    builtins.concatMap (
      weekday:
      map (start: {
        inherit (operationConfig) cadence;
        inherit start weekday;
      }) (orderedStarts operation operationConfig weekday)
    ) (candidateWeekdays operationConfig);
  allocateOperation =
    operation: initialAssignments: remainingHosts:
    let
      allocate =
        remaining: assignments: failures:
        if remaining == [ ] then
          { inherit assignments failures; }
        else
          let
            hostName = builtins.head remaining;
            operationConfig = policies.${hostName}.${operation};
            candidate = lib.findFirst (
              schedule:
              lib.all (
                assignedHost:
                let
                  assigned = assignments.${assignedHost};
                  exclusion = exclusionBetween hostName assignedHost operation;
                in
                !conflicts hostName assignedHost operation
                || !schedulesOverlap schedule assigned exclusion.minimumGapMinutes
              ) (builtins.attrNames assignments)
            ) null (scheduleCandidates operation operationConfig);
            fallbackWeekday = builtins.head (candidateWeekdays operationConfig);
            schedule =
              if candidate != null then
                candidate
              else
                {
                  inherit (operationConfig) cadence;
                  weekday = fallbackWeekday;
                  start = preferredStart operation operationConfig fallbackWeekday;
                };
          in
          if operationConfig.cadence == "never" then
            allocate (builtins.tail remaining) (
              assignments
              // {
                ${hostName} = {
                  cadence = "never";
                  calendar = null;
                  start = null;
                  weekday = null;
                };
              }
            ) failures
          else
            allocate (builtins.tail remaining)
              (
                assignments
                // {
                  ${hostName} = schedule // {
                    calendar = renderSchedule schedule;
                  };
                }
              )
              (
                failures
                ++ lib.optional (candidate == null) (
                  "${hostName}.${operation} has no non-overlapping slot in the allowed maintenance window"
                )
              );
    in
    allocate remainingHosts initialAssignments [ ];
  switchAllocation = allocateOperation "switch" { } hostNames;
  rebootReusesSwitch =
    hostName:
    policies.${hostName}.reboot.cadence != "never"
    && policies.${hostName}.reboot.cadence == policies.${hostName}.switch.cadence
    && policies.${hostName}.reboot.weekday == policies.${hostName}.switch.weekday;
  reusedRebootAssignments = builtins.listToAttrs (
    map (hostName: lib.nameValuePair hostName switchAllocation.assignments.${hostName}) (
      builtins.filter rebootReusesSwitch hostNames
    )
  );
  rebootAllocation = allocateOperation "reboot" reusedRebootAssignments (
    builtins.filter (hostName: !rebootReusesSwitch hostName) hostNames
  );
  rawPlans = lib.genAttrs hostNames (hostName: {
    switch = switchAllocation.assignments.${hostName};
    reboot = rebootAllocation.assignments.${hostName};
  });
  planFor =
    hostName:
    let
      raw = rawPlans.${hostName};
      rebootMode =
        if raw.reboot.cadence == "never" then
          "never"
        else if raw.reboot.calendar == raw.switch.calendar then
          "with-upgrade"
        else
          "scheduled";
    in
    {
      switch = raw.switch;
      reboot = raw.reboot // {
        mode = rebootMode;
        scheduledCalendar = if rebootMode == "scheduled" then raw.reboot.calendar else null;
      };
    };
in
{
  inherit
    policyMismatches
    unknownExclusionHosts
    weekdayConflicts
    ;
  failures = switchAllocation.failures ++ rebootAllocation.failures;
  plan = planFor localHost;
  plans = lib.genAttrs hostNames planFor;
}
