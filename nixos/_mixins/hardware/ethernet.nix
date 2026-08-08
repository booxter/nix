{
  config,
  pkgs,
  ...
}:
let
  mkDisablePauseService = interface: {
    description = "Disable Ethernet pause frames on ${interface}";
    after = [ "network-pre.target" ];
    wants = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.ethtool}/bin/ethtool -A ${interface} autoneg off rx off tx off";
      RemainAfterExit = true;
    };
  };
in
{
  systemd.services = builtins.listToAttrs (
    map (interface: {
      name = "ethtool-${interface}-disable-pause";
      value = mkDisablePauseService interface;
    }) config.host.network.pauseDisabledInterfaces
  );
}
