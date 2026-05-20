{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.nixosUpgrade;
  textfileCollectorHandledByOtherMixin =
    config.host.observability.lanWan.enable || config.host.observability.dnsQueryAccounting.enable;
  textfileCollectorNeeded = cfg.exportToNodeExporter && !textfileCollectorHandledByOtherMixin;
  writeSuccessMetric = pkgs.writeShellScript "write-nixos-upgrade-success-metric" ''
    set -euo pipefail

    ${pkgs.coreutils}/bin/mkdir -p ${cfg.textfileDir}
    tmp_file="$(${pkgs.coreutils}/bin/mktemp ${cfg.textfileDir}/nixos-upgrade.prom.XXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp_file"' EXIT

    cat >"$tmp_file" <<EOF
    # HELP node_nixos_upgrade_last_success_time_seconds Unix time of the last successful nixos-upgrade.service run.
    # TYPE node_nixos_upgrade_last_success_time_seconds gauge
    node_nixos_upgrade_last_success_time_seconds $(${pkgs.coreutils}/bin/date +%s)
    EOF

    ${pkgs.coreutils}/bin/mv "$tmp_file" ${cfg.textfileDir}/nixos-upgrade.prom
  '';
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

  config = lib.mkIf cfg.enable {
    systemd.services.nixos-upgrade.serviceConfig.ExecStartPost = "${writeSuccessMetric}";

    services.prometheus.exporters.node = lib.mkIf textfileCollectorNeeded {
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${cfg.textfileDir}" ];
    };

    systemd.tmpfiles.rules = lib.optional textfileCollectorNeeded "d ${cfg.textfileDir} 0755 root root - -";
  };
}
