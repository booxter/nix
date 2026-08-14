{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  pauseFrameInterfaces = builtins.attrNames (
    lib.filterAttrs (_: interface: interface.disablePauseFrames) config.host.network.interfaces
  );
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
  networking.dhcpcd.extraConfig = ''
    clientid ${config.networking.hostName}
  '';

  systemd.services = builtins.listToAttrs (
    map (interface: {
      name = "ethtool-${interface}-disable-pause";
      value = mkService interface;
    }) pauseFrameInterfaces
  );
}
