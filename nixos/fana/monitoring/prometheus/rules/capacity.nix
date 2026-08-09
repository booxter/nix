{
  facts,
  lib,
}:
let
  inherit (import ./lib.nix { inherit lib; }) mkAlert mkGroup;
  profiles = facts.observability.profiles.capacity;
  profileNames = builtins.attrNames profiles;
  mkCpuAlert =
    profileName: severity: threshold:
    mkAlert {
      name = if severity == "warning" then "NodeCpuUsageHigh" else "NodeCpuUsageCritical";
      expr = ''100 - (avg by(instance, job) (rate(node_cpu_seconds_total{scrape_profile="node",capacity_profile="${profileName}",mode="idle"}[5m])) * 100) > ${toString threshold}'';
      for = "5m";
      inherit severity;
      category = "capacity";
      summary = "Node CPU usage ${
        if severity == "warning" then "high" else "critical"
      } on {{ $labels.instance }}";
      description = "{{ $labels.instance }} CPU busy has been above ${toString threshold}% for 5 minutes.";
    };
  mkCpuAlerts =
    profileName:
    let
      policy = profiles.${profileName}.cpu or null;
    in
    lib.optionals (policy != null) [
      (mkCpuAlert profileName "warning" policy.warningPercent)
      (mkCpuAlert profileName "critical" policy.criticalPercent)
    ];
  mkMemoryAlert =
    profileName: severity: threshold:
    mkAlert {
      name = if severity == "warning" then "NodeMemoryUsageHigh" else "NodeMemoryUsageCritical";
      expr = ''max by(instance, job) (100 * (1 - (node_memory_MemAvailable_bytes{scrape_profile="node",capacity_profile="${profileName}"} / node_memory_MemTotal_bytes{scrape_profile="node",capacity_profile="${profileName}"}))) > ${toString threshold}'';
      for = "5m";
      inherit severity;
      category = "capacity";
      summary = "Node memory usage ${
        if severity == "warning" then "high" else "critical"
      } on {{ $labels.instance }}";
      description = "{{ $labels.instance }} memory usage has been above ${toString threshold}% for 5 minutes.";
    };
  mkPercentageMemoryAlerts =
    profileName:
    let
      policy = profiles.${profileName}.memory or null;
    in
    lib.optionals (policy != null && !(policy ? warningAvailableGiB)) [
      (mkMemoryAlert profileName "warning" policy.warningPercent)
      (mkMemoryAlert profileName "critical" policy.criticalPercent)
    ];
  hypervisorMemory = profiles.hypervisor.memory;
  mkHypervisorMemoryAlert =
    {
      name,
      severity,
      availableGiB,
      percent,
      level,
    }:
    mkAlert {
      inherit name severity;
      expr = ''max by(instance, job) ((node_memory_MemAvailable_bytes{scrape_profile="node",capacity_profile="hypervisor"} < ${toString availableGiB} * 1024 * 1024 * 1024) or (100 * (1 - (node_memory_MemAvailable_bytes{scrape_profile="node",capacity_profile="hypervisor"} / node_memory_MemTotal_bytes{scrape_profile="node",capacity_profile="hypervisor"})) > ${toString percent})) > 0'';
      for = "5m";
      category = "capacity";
      summary = "Hypervisor memory headroom ${level} on {{ $labels.instance }}";
      description = "{{ $labels.instance }} has less than ${toString availableGiB} GiB available or is above ${toString percent}% memory use for 5 minutes.";
    };
in
{
  groups = [
    (mkGroup {
      name = "fleet-capacity-policy";
      rules =
        builtins.concatMap mkCpuAlerts profileNames
        ++ builtins.concatMap mkPercentageMemoryAlerts profileNames
        ++ [
          (mkHypervisorMemoryAlert {
            name = "ProxmoxNodeMemoryHeadroomLow";
            severity = "warning";
            availableGiB = hypervisorMemory.warningAvailableGiB;
            percent = hypervisorMemory.warningPercent;
            level = "low";
          })
          (mkHypervisorMemoryAlert {
            name = "ProxmoxNodeMemoryHeadroomCritical";
            severity = "critical";
            availableGiB = hypervisorMemory.criticalAvailableGiB;
            percent = hypervisorMemory.criticalPercent;
            level = "critical";
          })
        ];
    })
  ];
}
