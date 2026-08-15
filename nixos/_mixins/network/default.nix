{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  pauseFrameInterfaces = lib.filterAttrs (
    _: interface: interface.disablePauseFrames
  ) config.host.network.interfaces;
  mkService = interface: {
    description = "Disable Ethernet pause frames on ${interface}";
    after = [ "network-pre.target" ];
    wants = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = utils.escapeSystemdExecArgs [
        (lib.getExe pkgs.ethtool)
        "-A"
        interface
        "autoneg"
        "off"
        "rx"
        "off"
        "tx"
        "off"
      ];
      RemainAfterExit = true;
    };
  };
in
{
  imports = [ ./dynamic-dns.nix ];

  networking.dhcpcd.extraConfig = ''
    clientid ${config.networking.hostName}
  '';

  systemd.services = lib.mapAttrs' (
    interface: _: lib.nameValuePair "ethtool-${interface}-disable-pause" (mkService interface)
  ) pauseFrameInterfaces;
}
