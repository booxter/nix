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
  qosInterface = if cfg.qos.interface != null then cfg.qos.interface else cfg.interface;
  qosClassMappings = lib.concatLines (
    lib.mapAttrsToList (label: classId: ''
      qos_class_ids[${lib.escapeShellArg classId}]=${lib.escapeShellArg label}
      qos_class_bytes[${lib.escapeShellArg label}]=0
    '') cfg.qos.classes
  );
  qosMetricLines = lib.concatLines (
    map (
      label:
      ''printf 'host_observability_qos_bytes_total{class="${label}",direction="transmit"} %s\n' "''${qos_class_bytes['${label}']}"''
    ) (lib.attrNames cfg.qos.classes)
  );
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

      set lan_nets6 {
        type ipv6_addr
        flags interval
        elements = { ${lib.concatStringsSep ", " cfg.lanSubnets6} }
      }

      counter lan_in {}
      counter wan_in {}
      counter lan_out {}
      counter wan_out {}

      chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        iifname "lo" return
        ${inputIfaceFilter}
        ip saddr @lan_nets counter name "lan_in" return
        ip6 saddr @lan_nets6 counter name "lan_in" return
        counter name "wan_in"
      }

      chain postrouting {
        type filter hook postrouting priority mangle; policy accept;
        oifname "lo" return
        ${outputIfaceFilter}
        ip daddr @lan_nets counter name "lan_out" return
        ip6 daddr @lan_nets6 counter name "lan_out" return
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
      pkgs.gawk
      pkgs.iproute2
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

      ${lib.optionalString cfg.qos.enable ''
        declare -A qos_class_ids=()
        declare -A qos_class_bytes=()
        ${qosClassMappings}

        qos_iface=${lib.escapeShellArg (if qosInterface != null then qosInterface else "")}
        if [[ -z "$qos_iface" ]]; then
          qos_iface="$(
            ip -o route show to default 2>/dev/null \
              | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
          )"
        fi

        if [[ -n "$qos_iface" ]]; then
          current_class=""
          while read -r field1 field2 field3 rest; do
            if [[ "$field1" == "class" ]]; then
              current_class="$field3"
            elif [[ "$field1" == "Sent" && -n "''${qos_class_ids[$current_class]:-}" ]]; then
              qos_class_bytes["''${qos_class_ids[$current_class]}"]="$field2"
            fi
          done < <(tc -s class show dev "$qos_iface")
        fi
      ''}

      {
        printf '%s\n' '# HELP host_observability_network_bytes_total Classified host network traffic in bytes.'
        printf '%s\n' '# TYPE host_observability_network_bytes_total counter'
        printf 'host_observability_network_bytes_total{direction="receive",scope="lan"} %s\n' "''${counter_bytes[lan_in]}"
        printf 'host_observability_network_bytes_total{direction="receive",scope="wan"} %s\n' "''${counter_bytes[wan_in]}"
        printf 'host_observability_network_bytes_total{direction="transmit",scope="lan"} %s\n' "''${counter_bytes[lan_out]}"
        printf 'host_observability_network_bytes_total{direction="transmit",scope="wan"} %s\n' "''${counter_bytes[wan_out]}"
        ${lib.optionalString cfg.qos.enable ''
          printf '%s\n' '# HELP host_observability_qos_bytes_total Traffic matched to exported tc QoS classes in bytes.'
          printf '%s\n' '# TYPE host_observability_qos_bytes_total counter'
          ${qosMetricLines}
        ''}
      } >"$tmp_file"

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

    lanSubnets6 = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "fe80::/10" ];
      description = "IPv6 subnets that should be treated as LAN traffic.";
    };

    interface = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "If set, only account traffic entering or leaving through this interface.";
    };

    qos = {
      enable = lib.mkEnableOption "export tc QoS class counters alongside LAN/WAN accounting";

      interface = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Interface to inspect for tc class counters; defaults to lanWan.interface.";
      };

      classes = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = { };
        example = {
          wg_capped = "1:10";
          other = "1:20";
        };
        description = "Mapping from exported metric label to tc class ID.";
      };
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
