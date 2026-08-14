{
  config,
  lib,
  ...
}:
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
      type = with lib.types; listOf (strMatching "^[0-9./]+$");
      default = [ config.host.site.lan.cidr ];
      description = "IPv4 subnets that should be treated as LAN traffic.";
    };

    lanSubnets6 = lib.mkOption {
      type = with lib.types; listOf (strMatching "^[0-9A-Fa-f:/]+$");
      default = [ "fe80::/10" ];
      description = "IPv6 subnets that should be treated as LAN traffic.";
    };

    interface = lib.mkOption {
      type = with lib.types; nullOr (strMatching "^[A-Za-z0-9_.:-]+$");
      default = config.host.network.primaryInterface;
      description = "Interface whose traffic should be accounted, or null to account all non-loopback traffic.";
    };

    wanEgressOverride = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            name = lib.mkOption {
              type = strMatching "^[A-Za-z_][A-Za-z0-9_]*$";
              description = "Metric label and nftables counter prefix for the overridden WAN class.";
            };
            udpDestinationPort = lib.mkOption {
              type = port;
              description = "Outbound UDP destination port identifying the overridden WAN class.";
            };
            tcClass = lib.mkOption {
              type = strMatching "^[0-9A-Fa-f]+:[0-9A-Fa-f]+$";
              description = "Traffic-control class whose byte count replaces the nftables subclass count.";
            };
          };
        });
      default = null;
      description = "Optional authoritative tc counter for one outbound WAN UDP class.";
    };
  };

  config.host.observability.lanWan = {
    enable = lib.mkDefault config.host.observability.enable;
    mode = lib.mkDefault (if config.host.proxmox.node != null then "host-local" else "interface-path");
  };
}
