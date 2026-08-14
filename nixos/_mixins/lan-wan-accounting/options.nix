{ lib, ... }:
{
  options.host.observability.lanWan = {
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
}
