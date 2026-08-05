{
  autoUpgradeTools,
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.observability.nixosUpgrade;
  textfileCollectorHandledByOtherMixin = config.host.observability.lanWan.enable;
  textfileCollectorNeeded = cfg.exportToNodeExporter && !textfileCollectorHandledByOtherMixin;
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
      default = "/var/lib/prometheus-node-exporter-textfile";
      description = "Directory used for the node exporter textfile metric.";
    };
  };

  config = lib.mkMerge [
    {
      host.observability.nixosUpgrade = {
        enable = lib.mkDefault true;
        exportToNodeExporter = lib.mkDefault (!config.host.isWork);
      };
    }
    (lib.mkIf cfg.enable {
      systemd.services.nixos-upgrade.serviceConfig.ExecStartPost = "${writeSuccessMetric}";

      services.prometheus.exporters.node = lib.mkIf textfileCollectorNeeded {
        enabledCollectors = [ "textfile" ];
        extraFlags = [ "--collector.textfile.directory=${cfg.textfileDir}" ];
      };

      systemd.tmpfiles.rules =
        lib.optional cfg.exportToNodeExporter "d ${cfg.textfileDir} 0755 root root - -"
        ++ lib.optional cfg.exportToNodeExporter "z ${cfg.textfileDir}/nixos-upgrade.prom 0644 root root - -";
    })
  ];
}
