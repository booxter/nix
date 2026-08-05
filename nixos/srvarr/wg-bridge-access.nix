{
  config,
  hostInventory,
  lib,
  pkgs,
  srvarrPkgs,
  utils,
  ...
}:
let
  cfg = config.host.vpnNamespaceBridgeAccess;
  wgBridgeAddress = hostInventory.nixosHostSpecsByName.srvarr.wgNamespace.bridgeAddress;
  tcpPorts = lib.unique cfg.tcpPorts;
  bridgeAccessConfig = (pkgs.formats.json { }).generate "wg-bridge-access.json" {
    namespace = "wg";
    sourceAddress = wgBridgeAddress;
    inherit tcpPorts;
  };
  bridgeAccessCommand =
    action:
    utils.escapeSystemdExecArgs [
      (lib.getExe srvarrPkgs.network-tools)
      action
      "--config"
      bridgeAccessConfig
    ];
in
{
  options.host.vpnNamespaceBridgeAccess.tcpPorts = lib.mkOption {
    type = with lib.types; listOf port;
    default = [ ];
    description = "TCP ports inside the wg namespace that the host bridge may proxy to.";
  };

  config = lib.mkIf (tcpPorts != [ ]) {
    systemd.services.wg-bridge-access = {
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        After = [ "wg.service" ];
        BindsTo = [ "wg.service" ];
        PartOf = [ "wg.service" ];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = bridgeAccessCommand "apply";
        ExecStop = bridgeAccessCommand "remove";
      };
    };
  };
}
