{
  autoUpgradeTools,
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.observability.nixosUpgrade;
  writeSuccessMetric = utils.escapeSystemdExecArgs [
    (lib.getExe autoUpgradeTools)
    "write-success-metric"
    "--output"
    "${cfg.textfileDir}/nixos-upgrade.prom"
  ];
in
{
  options.host.observability.nixosUpgrade = {
    enable = lib.mkEnableOption "successful NixOS upgrade timestamp tracking";

    exportToNodeExporter = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to expose successful upgrade timestamps through node exporter's textfile collector.";
    };

    textfileDir = lib.mkOption {
      type = lib.types.str;
      default = config.host.observability.nodeExporter.textfile.directory;
      description = "Directory used for the node exporter textfile metric.";
    };
  };

  config = lib.mkMerge [
    {
      host.observability.nixosUpgrade = {
        enable = lib.mkDefault config.host.observability.enable;
        exportToNodeExporter = lib.mkDefault config.host.observability.enable;
      };
    }
    (lib.mkIf cfg.enable {
      host.observability.nodeExporter.textfile.enable = cfg.exportToNodeExporter;

      systemd.services.nixos-upgrade.serviceConfig.ExecStartPost = "${writeSuccessMetric}";

      systemd.tmpfiles.rules =
        lib.optional cfg.exportToNodeExporter "d ${cfg.textfileDir} 0755 root root - -"
        ++ lib.optional cfg.exportToNodeExporter "z ${cfg.textfileDir}/nixos-upgrade.prom 0644 root root - -";
    })
  ];
}
