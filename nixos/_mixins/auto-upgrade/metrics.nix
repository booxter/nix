{
  autoUpgradeTools,
  config,
  lib,
  utils,
  ...
}:
let
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  writeSuccessMetric = utils.escapeSystemdExecArgs [
    (lib.getExe autoUpgradeTools)
    "write-success-metric"
    "--output"
    "${textfileDir}/nixos-upgrade.prom"
  ];
in
{
  config = lib.mkIf config.host.observability.enable {
    systemd.services.nixos-upgrade.serviceConfig.ExecStartPost = "${writeSuccessMetric}";

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root - -"
      "z ${textfileDir}/nixos-upgrade.prom 0644 root root - -"
    ];
  };
}
