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
  interfacePathMode = cfg.mode == "interface-path";
  wanSubclassEnabled = cfg.wanUdpSubclass != null;
  wanTransmitTcClassEnabled = cfg.wanTransmitTcClass != null;
  inputIfaceFilter = lib.optionalString (cfg.interface != null) ''
    iifname != "${cfg.interface}" return
  '';
  outputIfaceFilter = lib.optionalString (cfg.interface != null) ''
    oifname != "${cfg.interface}" return
  '';
  wanSubclassRules = lib.optionalString wanSubclassEnabled ''
    udp dport ${toString cfg.wanUdpSubclass.port} counter name "${cfg.wanUdpSubclass.name}_out"
    udp dport ${toString cfg.wanUdpSubclass.port} counter name "wan_out" return
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
      ${lib.optionalString wanSubclassEnabled "counter ${cfg.wanUdpSubclass.name}_out {}"}
      ${lib.optionalString wanSubclassEnabled "counter wan_other_out {}"}

      chain ${if interfacePathMode then "prerouting" else "input"} {
        type filter hook ${
          if interfacePathMode then "prerouting" else "input"
        } priority mangle; policy accept;
        iifname "lo" return
        ${inputIfaceFilter}
        ip saddr @lan_nets counter name "lan_in" return
        ip6 saddr @lan_nets6 counter name "lan_in" return
        counter name "wan_in"
      }

      chain ${if interfacePathMode then "postrouting" else "output"} {
        type filter hook ${
          if interfacePathMode then "postrouting" else "output"
        } priority mangle; policy accept;
        oifname "lo" return
        ${outputIfaceFilter}
        ip daddr @lan_nets counter name "lan_out" return
        ip6 daddr @lan_nets6 counter name "lan_out" return
        ${wanSubclassRules}
        ${lib.optionalString wanSubclassEnabled ''counter name "wan_other_out"''}
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
      pkgs.jq
      pkgs.iproute2
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
        ${lib.optionalString wanSubclassEnabled "[${cfg.wanUdpSubclass.name}_out]=0"}
        ${lib.optionalString wanSubclassEnabled "[wan_other_out]=0"}
      )

      while read -r counter_name counter_value; do
        counter_bytes["$counter_name"]="$counter_value"
      done < <(
        nft -j list table inet ${tableName} | jq -r '
          .nftables[]
          | .counter?
          | select(
              .name == "lan_in"
              or .name == "wan_in"
              or .name == "lan_out"
              or .name == "wan_out"
              ${lib.optionalString wanSubclassEnabled ''or .name == "${cfg.wanUdpSubclass.name}_out" or .name == "wan_other_out"''}
            )
          | "\(.name) \(.bytes)"
        '
      )

      ${lib.optionalString wanTransmitTcClassEnabled ''
        tc_wan_bytes="$(
          tc -s class show dev ${cfg.interface} | awk '
            /^class htb ${cfg.wanTransmitTcClass} / { getline; print $2; found = 1; exit }
            END { if (!found) print 0 }
          '
        )"
        ${lib.optionalString wanSubclassEnabled ''
          counter_bytes[${cfg.wanUdpSubclass.name}_out]="$tc_wan_bytes"
          counter_bytes[wan_out]="$(( tc_wan_bytes + counter_bytes[wan_other_out] ))"
        ''}
        ${lib.optionalString (!wanSubclassEnabled) ''
          counter_bytes[wan_out]="$tc_wan_bytes"
        ''}
      ''}

      {
        printf '%s\n' '# HELP host_observability_network_bytes_total Classified network traffic observed on this host (per packet path/interface) in bytes.'
        printf '%s\n' '# TYPE host_observability_network_bytes_total counter'
        printf 'host_observability_network_bytes_total{direction="receive",scope="lan"} %s\n' "''${counter_bytes[lan_in]}"
        printf 'host_observability_network_bytes_total{direction="receive",scope="wan"} %s\n' "''${counter_bytes[wan_in]}"
        printf 'host_observability_network_bytes_total{direction="transmit",scope="lan"} %s\n' "''${counter_bytes[lan_out]}"
        printf 'host_observability_network_bytes_total{direction="transmit",scope="wan"} %s\n' "''${counter_bytes[wan_out]}"
        ${lib.optionalString wanSubclassEnabled ''
          printf '%s\n' '# HELP host_observability_network_wan_subclass_bytes_total Classified outbound WAN traffic in bytes by subclass.'
          printf '%s\n' '# TYPE host_observability_network_wan_subclass_bytes_total counter'
          printf 'host_observability_network_wan_subclass_bytes_total{class="${cfg.wanUdpSubclass.name}"} %s\n' "''${counter_bytes[${cfg.wanUdpSubclass.name}_out]}"
          printf 'host_observability_network_wan_subclass_bytes_total{class="other"} %s\n' "''${counter_bytes[wan_other_out]}"
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

    mode = lib.mkOption {
      type = lib.types.enum [
        "interface-path"
        "host-local"
      ];
      default = "interface-path";
      description = "Whether to account traffic on the interface path or only traffic generated/consumed by the host itself.";
    };

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

    wanUdpSubclass = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            name = lib.mkOption {
              type = str;
              description = "Subclass label to use for matched outbound WAN UDP traffic.";
            };

            port = lib.mkOption {
              type = port;
              description = "Destination UDP port to classify as a special outbound WAN subclass.";
            };
          };
        });
      default = null;
      description = "Optional explicit outbound WAN UDP subclass to count alongside the generic WAN counter.";
    };

    wanTransmitTcClass = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Optional tc class ID to use as the authoritative outbound WAN byte counter for this host.";
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

    assertions = [
      {
        assertion = cfg.wanTransmitTcClass == null || cfg.interface != null;
        message = "host.observability.lanWan.wanTransmitTcClass requires host.observability.lanWan.interface to be set.";
      }
      {
        assertion = cfg.wanTransmitTcClass == null || cfg.wanUdpSubclass != null;
        message = "host.observability.lanWan.wanTransmitTcClass requires host.observability.lanWan.wanUdpSubclass so WAN total can include unmatched WAN traffic.";
      }
    ];
  };
}
