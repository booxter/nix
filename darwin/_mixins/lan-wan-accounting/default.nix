{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.lanWan;
  nodeCfg = config.services.prometheus.exporters.node;
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  anchorLeaf = "booxter_observability_lan_wan";
  anchorName = "com.apple/${anchorLeaf}";
  anchorPath = "/etc/pf.anchors/${anchorLeaf}";
  iface = cfg.interface;
  pfRules = pkgs.writeText "darwin-lan-wan-accounting.pf" ''
    pass in quick on ${iface} inet from { ${lib.concatStringsSep ", " cfg.lanSubnets} } to any no state label "lan_in"
    pass in quick on ${iface} inet6 from { ${lib.concatStringsSep ", " cfg.lanSubnets6} } to any no state label "lan_in"
    pass in quick on ${iface} all no state label "wan_in"

    pass out quick on ${iface} inet from any to { ${lib.concatStringsSep ", " cfg.lanSubnets} } no state label "lan_out"
    pass out quick on ${iface} inet6 from any to { ${lib.concatStringsSep ", " cfg.lanSubnets6} } no state label "lan_out"
    pass out quick on ${iface} all no state label "wan_out"
  '';
  installRules = pkgs.writeShellApplication {
    name = "darwin-lan-wan-accounting-install";
    text = ''
      set -euo pipefail

      mkdir -p ${textfileDir} /etc/pf.anchors
      install -m 0644 ${pfRules} ${anchorPath}

      /sbin/pfctl -E >/dev/null 2>&1 || true
      /sbin/pfctl -a ${anchorName} -f ${anchorPath}
    '';
  };
  exportMetrics = pkgs.writeShellApplication {
    name = "darwin-lan-wan-accounting-export";
    runtimeInputs = [
      pkgs.coreutils
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

      current_label=""
      while IFS= read -r line; do
        if [[ "$line" =~ label[[:space:]]+\"([^\"]+)\" ]]; then
          current_label="''${BASH_REMATCH[1]}"
          continue
        fi

        if [[ -n "$current_label" && "$line" =~ Bytes:[[:space:]]*([0-9]+) ]]; then
          counter_bytes["$current_label"]="''${BASH_REMATCH[1]}"
          current_label=""
        fi
      done < <(/sbin/pfctl -a ${anchorName} -sr -v 2>/dev/null || true)

      {
        printf '%s\n' '# HELP host_observability_network_bytes_total Classified host network traffic in bytes.'
        printf '%s\n' '# TYPE host_observability_network_bytes_total counter'
        printf 'host_observability_network_bytes_total{direction="receive",scope="lan"} %s\n' "''${counter_bytes[lan_in]}"
        printf 'host_observability_network_bytes_total{direction="receive",scope="wan"} %s\n' "''${counter_bytes[wan_in]}"
        printf 'host_observability_network_bytes_total{direction="transmit",scope="lan"} %s\n' "''${counter_bytes[lan_out]}"
        printf 'host_observability_network_bytes_total{direction="transmit",scope="wan"} %s\n' "''${counter_bytes[wan_out]}"
      } >"$tmp_file"

      chmod 0644 "$tmp_file"
      mv "$tmp_file" ${textfileDir}/lan-wan.prom
      trap - EXIT
    '';
  };
in
{
  options.host.observability.lanWan = {
    enable = lib.mkEnableOption "LAN/WAN traffic accounting for Prometheus on Darwin";

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
      type = lib.types.str;
      example = "en0";
      description = "Primary network interface to classify traffic on.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      extraFlags = [
        "--collector.textfile"
        "--collector.textfile.directory=${textfileDir}"
      ];
    };

    # Work around nix-darwin node-exporter flag joining until
    # https://github.com/nix-darwin/nix-darwin/pull/1739 lands.
    launchd.daemons.prometheus-node-exporter.serviceConfig.ProgramArguments = lib.mkForce [
      "/bin/sh"
      "-c"
      "/bin/wait4path /nix/store && exec ${lib.getExe nodeCfg.package} --web.listen-address ${nodeCfg.listenAddress}:${toString nodeCfg.port} --collector.textfile --collector.textfile.directory=${textfileDir}"
    ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      mkdir -p ${textfileDir}
      chmod 0755 ${textfileDir}
    '';

    launchd.daemons.observability-lan-wan-accounting = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe installRules) ];
        RunAtLoad = true;
        StandardOutPath = "/var/log/observability-lan-wan-accounting.log";
        StandardErrorPath = "/var/log/observability-lan-wan-accounting.log";
      };
    };

    launchd.daemons.observability-lan-wan-export = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe exportMetrics) ];
        RunAtLoad = true;
        StartInterval = 15;
        StandardOutPath = "/var/log/observability-lan-wan-export.log";
        StandardErrorPath = "/var/log/observability-lan-wan-export.log";
      };
    };
  };
}
