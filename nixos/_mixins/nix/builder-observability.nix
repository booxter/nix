{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nix.builder;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
in
{
  config = lib.mkIf (cfg != null && config.host.observability.enable) {
    host.observability.nodeExporter.textfile.periodicProducers.nix-builder-metrics = {
      description = "Collect active Nix builder cgroup metrics";
      command = [
        (lib.getExe pkgs.nix-builder-metrics)
        "--configured-slots"
        (toString config.nix.settings.max-jobs)
        "--cgroup-root"
        "/sys/fs/cgroup/system.slice/nix-daemon.service"
        "--output-file"
        "${textfileDir}/nix-builder.prom"
      ];
      interval = "15s";
      onBootSec = "15s";
    };
  };
}
