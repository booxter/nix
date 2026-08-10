{
  facts,
  lib,
}:
let
  inherit (import ./lib.nix { inherit lib; }) mkAlert mkGroup;
  policy = facts.observability.capacity;
  cpuUsage = ''
    100 - (
      avg by(instance, job) (
        rate(node_cpu_seconds_total{scrape_profile="node",host_laptop="false",host_builder="false",mode="idle"}[5m])
        or rate(node_cpu_seconds_total{scrape_profile="node",host_laptop="false",host_hypervisor="true",mode="idle"}[5m])
      ) * 100
    )
  '';
  memoryUsage = ''
    max by(instance, job) (
      100 * (
        1 - (
          node_memory_MemAvailable_bytes{scrape_profile="node",host_laptop="false",host_hypervisor="false"}
          / node_memory_MemTotal_bytes{scrape_profile="node",host_laptop="false",host_hypervisor="false"}
        )
      )
    )
  '';
  mkCpuAlert =
    severity: threshold:
    mkAlert {
      name = if severity == "warning" then "NodeCpuUsageHigh" else "NodeCpuUsageCritical";
      expr = "${cpuUsage} > ${toString threshold}";
      for = "5m";
      inherit severity;
      category = "capacity";
      summary = "Node CPU usage ${
        if severity == "warning" then "high" else "critical"
      } on {{ $labels.instance }}";
      description = "{{ $labels.instance }} CPU busy has been above ${toString threshold}% for 5 minutes.";
    };
  mkMemoryAlert =
    severity: threshold:
    mkAlert {
      name = if severity == "warning" then "NodeMemoryUsageHigh" else "NodeMemoryUsageCritical";
      expr = "${memoryUsage} > ${toString threshold}";
      for = "5m";
      inherit severity;
      category = "capacity";
      summary = "Node memory usage ${
        if severity == "warning" then "high" else "critical"
      } on {{ $labels.instance }}";
      description = "{{ $labels.instance }} memory usage has been above ${toString threshold}% for 5 minutes.";
    };
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
      expr = ''
        max by(instance, job) (
          (
            node_memory_MemAvailable_bytes{scrape_profile="node",host_hypervisor="true"}
            < ${toString availableGiB} * 1024 * 1024 * 1024
          )
          or (
            100 * (
              1 - (
                node_memory_MemAvailable_bytes{scrape_profile="node",host_hypervisor="true"}
                / node_memory_MemTotal_bytes{scrape_profile="node",host_hypervisor="true"}
              )
            ) > ${toString percent}
          )
        ) > 0
      '';
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
      rules = [
        (mkCpuAlert "warning" policy.cpu.warningPercent)
        (mkCpuAlert "critical" policy.cpu.criticalPercent)
        (mkMemoryAlert "warning" policy.memory.warningPercent)
        (mkMemoryAlert "critical" policy.memory.criticalPercent)
        (mkHypervisorMemoryAlert {
          name = "ProxmoxNodeMemoryHeadroomLow";
          severity = "warning";
          availableGiB = policy.hypervisorMemory.warningAvailableGiB;
          percent = policy.hypervisorMemory.warningPercent;
          level = "low";
        })
        (mkHypervisorMemoryAlert {
          name = "ProxmoxNodeMemoryHeadroomCritical";
          severity = "critical";
          availableGiB = policy.hypervisorMemory.criticalAvailableGiB;
          percent = policy.hypervisorMemory.criticalPercent;
          level = "critical";
        })
      ];
    })
  ];
}
