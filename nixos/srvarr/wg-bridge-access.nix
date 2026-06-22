{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.vpnNamespaceBridgeAccess;
  wgBridgeAddress = hostInventory.nixosHostSpecsByName.srvarr.wgNamespace.bridgeAddress;
  tcpPorts = lib.unique cfg.tcpPorts;
  bridgeAccessScript = pkgs.writeShellApplication {
    name = "wg-bridge-access";
    runtimeInputs = [
      pkgs.iproute2
      pkgs.iptables
    ];
    text = ''
      set -euo pipefail

      case "''${1:-start}" in
        start)
          for port in ${lib.escapeShellArgs (map builtins.toString tcpPorts)}; do
            rule=(-s ${wgBridgeAddress}/32 -p tcp --dport "$port" -j ACCEPT)
            ip netns exec wg iptables -C INPUT "''${rule[@]}" 2>/dev/null \
              || ip netns exec wg iptables -I INPUT 1 "''${rule[@]}"
          done
          ;;
        stop)
          for port in ${lib.escapeShellArgs (map builtins.toString tcpPorts)}; do
            rule=(-s ${wgBridgeAddress}/32 -p tcp --dport "$port" -j ACCEPT)
            ip netns exec wg iptables -D INPUT "''${rule[@]}" 2>/dev/null || true
          done
          ;;
        *)
          echo "usage: $0 [start|stop]" >&2
          exit 2
          ;;
      esac
    '';
  };
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
        ExecStart = "${lib.getExe bridgeAccessScript} start";
        ExecStop = "${lib.getExe bridgeAccessScript} stop";
      };
    };
  };
}
