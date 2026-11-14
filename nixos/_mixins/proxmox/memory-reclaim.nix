{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.memoryReclaim;
  producer = config.host.observability.nodeExporter.textfile.periodicProducers.memory-reclaim-metrics;
in
{
  config = lib.mkIf (config.host.proxmox.node != null) {
    # Match individual VMs as they start or migrate, keeping the reserve and
    # pressure backoff per guest. Leave balloon targets and the THP policy alone.
    # Reclaim requests can release more memory than their requested size.
    host.memoryReclaim = {
      enable = lib.mkDefault true;
      cgroups = [ "qemu.slice/*.scope" ];
    };

    host.observability.nodeExporter.textfile.periodicProducers.memory-reclaim-metrics =
      lib.mkIf (cfg.enable && config.host.observability.enable)
        {
          description = "Measure VM memory retention and reclaim pressure";
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
          ]) cfg.cgroups;
        };
  };
}
