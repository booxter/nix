{
  fleetInventory,
  lib,
  outputs,
}:
let
  inventory = fleetInventory.autoUpgrade;
  nixosHosts = lib.filterAttrs (_: host: host.platform == "nixos") fleetInventory.hosts;
  hostNames = builtins.attrNames nixosHosts;
  realmNames = lib.unique (map (hostName: nixosHosts.${hostName}.realm) hostNames);
  claimsByHost = lib.genAttrs hostNames (
    hostName: outputs.nixosConfigurations.${hostName}.config.host.autoUpgrade.claims
  );
  hostNamesForRealm =
    realm: builtins.attrNames (lib.filterAttrs (_: host: host.realm == realm) nixosHosts);
  realmEvaluations = lib.genAttrs realmNames (
    realm:
    import ./plan.nix {
      hostNames = hostNamesForRealm realm;
      inherit claimsByHost lib;
      policy = inventory.policy;
    }
  );
  calculatedPlans = lib.foldl' (
    plans: realm: plans // realmEvaluations.${realm}.plans
  ) { } realmNames;
  scheduleFor = plan: {
    switch = plan.switch.calendar;
    reboot = {
      inherit (plan.reboot) mode;
      calendar = plan.reboot.scheduledCalendar;
    };
  };
  calculatedSchedules = lib.mapAttrs (_: scheduleFor) calculatedPlans;
  committedSchedules = inventory.schedules;
  committedHostNames = builtins.attrNames committedSchedules;
  missingHosts = builtins.filter (hostName: !builtins.hasAttr hostName committedSchedules) hostNames;
  extraHosts = builtins.filter (hostName: !builtins.hasAttr hostName nixosHosts) committedHostNames;
  comparableHostNames = builtins.filter (
    hostName: builtins.hasAttr hostName committedSchedules
  ) hostNames;
  driftedHosts = builtins.filter (
    hostName: committedSchedules.${hostName} != calculatedSchedules.${hostName}
  ) comparableHostNames;
  realmErrors = builtins.concatMap (
    realm:
    let
      evaluation = realmEvaluations.${realm};
    in
    lib.optional (evaluation.unknownExclusionHosts != [ ]) (
      "realm '${realm}' auto-upgrade exclusions name unknown or out-of-realm hosts: "
      + lib.concatStringsSep ", " evaluation.unknownExclusionHosts
    )
    ++ evaluation.weekdayConflicts
    ++ evaluation.failures
  ) realmNames;
in
{
  inherit
    calculatedSchedules
    claimsByHost
    committedSchedules
    driftedHosts
    extraHosts
    hostNames
    missingHosts
    nixosHosts
    ;
  errors =
    realmErrors
    ++ lib.optional (missingHosts != [ ]) (
      "auto-upgrade schedule inventory is missing hosts: ${lib.concatStringsSep ", " missingHosts}"
    )
    ++ lib.optional (extraHosts != [ ]) (
      "auto-upgrade schedule inventory has unknown hosts: ${lib.concatStringsSep ", " extraHosts}"
    )
    ++ map (
      hostName:
      "auto-upgrade schedule for '${hostName}' is ${
        builtins.toJSON committedSchedules.${hostName}
      }, calculated ${builtins.toJSON calculatedSchedules.${hostName}}"
    ) driftedHosts;
}
