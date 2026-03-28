{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.lanWan;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  tableName = "observability_lan_wan";
  inputIfaceFilter = lib.optionalString (cfg.interface != null) ''
    iifname != "${cfg.interface}" return
  '';
  outputIfaceFilter = lib.optionalString (cfg.interface != null) ''
    oifname != "${cfg.interface}" return
  '';
  rulesFile = pkgs.writeText "lan-wan-accounting.nft" ''
    table inet ${tableName} {
      set lan_nets {
        type ipv4_addr
        flags interval
        elements = { ${lib.concatStringsSep ", " cfg.lanSubnets} }
      }

      counter lan_in {}
      counter wan_in {}
      counter lan_out {}
      counter wan_out {}

      chain input {
        type filter hook input priority mangle; policy accept;
        iifname "lo" return
        ${inputIfaceFilter}
        ip saddr @lan_nets counter name "lan_in" return
        counter name "wan_in"
      }

      chain output {
        type filter hook output priority mangle; policy accept;
        oifname "lo" return
        ${outputIfaceFilter}
        ip daddr @lan_nets counter name "lan_out" return
        counter name "wan_out"
      }
    }
  '';
  installRules = pkgs.writeShellApplication {
    name = "lan-wan-accounting-install";
    runtimeInputs = [
      pkgs.nftables
    ];
    text = ''
      set -euo pipefail
      nft delete table inet ${tableName} 2>/dev/null || true
      nft -f ${rulesFile}
    '';
  };
  removeRules = pkgs.writeShellApplication {
    name = "lan-wan-accounting-remove";
    runtimeInputs = [
      pkgs.nftables
    ];
    text = ''
      set -euo pipefail
      nft delete table inet ${tableName} 2>/dev/null || true
    '';
  };
  exportMetrics = pkgs.writeShellApplication {
    name = "lan-wan-accounting-export";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.nftables
    ];
    text = ''
      set -euo pipefail

      tmp_file="$(mktemp ${textfileDir}/lan-wan.prom.XXXXXX)"
      trap 'rm -f "$tmp_file"' EXIT

      declare -A counter_bytes=(
        [lan_in]=0
        [wan_in]=0
        [lan_out]=0
        [wan_out]=0
      )

      while read -r counter_name counter_value; do
        counter_bytes["$counter_name"]="$counter_value"
      done < <(
        nft -j list table inet ${tableName} | jq -r '
          .nftables[]
          | .counter?
          | select(.name == "lan_in" or .name == "wan_in" or .name == "lan_out" or .name == "wan_out")
          | "\(.name) \(.bytes)"
        '
      )

      cat >"$tmp_file" <<EOF
      # HELP host_observability_network_bytes_total Classified host network traffic in bytes.
      # TYPE host_observability_network_bytes_total counter
      host_observability_network_bytes_total{direction="receive",scope="lan"} ''${counter_bytes[lan_in]}
      host_observability_network_bytes_total{direction="receive",scope="wan"} ''${counter_bytes[wan_in]}
      host_observability_network_bytes_total{direction="transmit",scope="lan"} ''${counter_bytes[lan_out]}
      host_observability_network_bytes_total{direction="transmit",scope="wan"} ''${counter_bytes[wan_out]}
      EOF

      chmod 0644 "$tmp_file"
      mv "$tmp_file" ${textfileDir}/lan-wan.prom
      trap - EXIT
    '';
  };
in
{
  options.host.observability.lanWan = {
    enable = lib.mkEnableOption "LAN/WAN traffic accounting for Prometheus";

    lanSubnets = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "192.168.0.0/16" ];
      description = "IPv4 subnets that should be treated as LAN traffic.";
    };

    interface = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "If set, only account traffic entering or leaving through this interface.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enabledCollectors = [ "textfile" ];
      extraFlags = [ "--collector.textfile.directory=${textfileDir}" ];
    };

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root - -"
    ];

    systemd.services.observability-lan-wan-accounting = {
      description = "Install nftables LAN/WAN accounting rules";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-pre.target" ];
      wants = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe installRules;
        ExecStop = lib.getExe removeRules;
      };
    };

    systemd.services.observability-lan-wan-export = {
      description = "Export LAN/WAN accounting metrics for node exporter";
      after = [ "observability-lan-wan-accounting.service" ];
      requires = [ "observability-lan-wan-accounting.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe exportMetrics;
      };
    };

    systemd.timers.observability-lan-wan-export = {
      description = "Refresh LAN/WAN accounting metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "15s";
        Unit = "observability-lan-wan-export.service";
      };
    };
  };
}
