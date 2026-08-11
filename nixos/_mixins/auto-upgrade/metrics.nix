{
  autoUpgradeTools,
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.observability.nixosUpgrade;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  writeSuccessMetric = utils.escapeSystemdExecArgs [
    (lib.getExe autoUpgradeTools)
    "write-success-metric"
    "--output"
    "${textfileDir}/nixos-upgrade.prom"
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
  };

  config = lib.mkMerge [
    {
      host.observability.nixosUpgrade = {
        enable = lib.mkDefault config.host.observability.enable;
        exportToNodeExporter = lib.mkDefault config.host.observability.enable;
      };
    }
    (lib.mkIf (cfg.enable && config.host.autoUpgrade.enable) {
      systemd.services.nixos-upgrade.serviceConfig.ExecStartPost = "${writeSuccessMetric}";

      systemd.tmpfiles.rules =
        lib.optional cfg.exportToNodeExporter "d ${textfileDir} 0755 root root - -"
        ++ lib.optional cfg.exportToNodeExporter "z ${textfileDir}/nixos-upgrade.prom 0644 root root - -";
    })
  ];
}
