{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
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
  exporter = pkgs.callPackage ./pkgs/lan-wan-exporter { };
  nft = lib.getExe pkgs.nftables;
  removeCommand = utils.escapeSystemdExecArgs [
    nft
    "delete"
    "table"
    "inet"
    tableName
  ];
  exportCommand = utils.escapeSystemdExecArgs (
    [
      (lib.getExe exporter)
      "--table"
      tableName
      "--output"
      "${textfileDir}/lan-wan.prom"
    ]
    ++ lib.optionals wanSubclassEnabled [
      "--wan-subclass"
      cfg.wanUdpSubclass.name
    ]
    ++ lib.optionals wanTransmitTcClassEnabled [
      "--interface"
      cfg.interface
      "--wan-tc-class"
      cfg.wanTransmitTcClass
    ]
  );
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
      default = [ hostInventory.site.lan.cidr ];
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

  config = lib.mkMerge [
    {
      host.observability.lanWan = {
        enable = lib.mkDefault (!config.host.isWork);
        mode = lib.mkDefault (if config.host.isProxmox then "host-local" else "interface-path");
      };
    }
    (lib.mkIf cfg.enable {
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
          ExecStartPre = "-${removeCommand}";
          ExecStart = utils.escapeSystemdExecArgs [
            nft
            "-f"
            rulesFile
          ];
          ExecStop = "-${removeCommand}";
        };
      };

      systemd.services.observability-lan-wan-export = {
        description = "Export LAN/WAN accounting metrics for node exporter";
        after = [ "observability-lan-wan-accounting.service" ];
        requires = [ "observability-lan-wan-accounting.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = exportCommand;
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
    })
  ];
}
