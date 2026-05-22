{ pkgs, ... }:
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
  systemd.services.ethtool-enp6s0-disable-pause = mkDisablePauseService "enp6s0";
  systemd.services.ethtool-enp7s0-disable-pause = mkDisablePauseService "enp7s0";
}
