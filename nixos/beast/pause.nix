{
  config,
  pkgs,
  ...
}:
let
  mkDisablePauseService = iface: {
    description = "Disable Ethernet pause frames on ${iface}";
    after = [ "network-pre.target" ];
    wants = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.ethtool}/bin/ethtool -A ${iface} autoneg off rx off tx off";
      RemainAfterExit = true;
    };
  };
in
{
  # Link on TL2-F7120 can drop intermittently; disabling pause frames here
  # has helped stability. Flow control is also disabled on the switch port.
  systemd.services = builtins.listToAttrs (
    map (interface: {
      name = "ethtool-${interface}-disable-pause";
      value = mkDisablePauseService interface;
    }) config.host.network.pauseDisabledInterfaces
  );
}
