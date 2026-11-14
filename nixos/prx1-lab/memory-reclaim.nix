{
  config,
  lib,
  pkgs,
  ...
}:
let
  producer = config.host.observability.nodeExporter.textfile.periodicProducers.memory-reclaim-metrics;
in
{
  # CI-only trial: leave Proxmox's balloon targets and the host THP policy alone.
  # Senpai includes retained anonymous memory in its reclaimable estimate and
  # backs off on memory/IO stalls. Requests can overshoot their size.
  host.memoryReclaim = {
    enable = true;
    cgroups = [ "qemu.slice/115.scope" ];
    reserveMiB = 1024;
    intervalSeconds = 60;
    probeFraction = 0.01;
    pressurePercent = 0.1;
  };

  host.observability.nodeExporter.textfile.periodicProducers.memory-reclaim-metrics = {
    description = "Measure CI memory retention and reclaim pressure";
    interval = "15s";
    accuracySec = "1s";
    command = [
      (lib.getExe pkgs.memory-reclaim-metrics)
      "--output-file"
      "${producer.directory}/memory-reclaim.prom"
    ]
    ++ lib.concatMap (group: [
      "--cgroup"
      group
    ]) config.host.memoryReclaim.cgroups;
  };
}
