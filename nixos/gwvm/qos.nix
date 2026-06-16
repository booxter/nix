{
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  wgHome = hostInventory.site.wireguard.home;
  lanInterface = "ens18";
  wgListenPort = wgHome.gateway.listenPort;
  vpnUploadCapRate = "10mbit";
  outerLinkRate = "10gbit";
in
{
  # Keep WireGuard peer downloads from filling the constrained home uplink.
  systemd.services.wg-qos = {
    description = "Cap outbound home WireGuard traffic";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "wireguard-wg0.service"
    ];
    bindsTo = [ "wireguard-wg0.service" ];
    partOf = [ "wireguard-wg0.service" ];
    serviceConfig =
      let
        wgQosScript = pkgs.writeShellApplication {
          name = "wg-qos";
          runtimeInputs = [
            pkgs.iproute2
          ];
          text = ''
            set -euo pipefail

            iface=${lib.escapeShellArg lanInterface}

            case "''${1:-start}" in
              start)
                tc qdisc del dev "$iface" root 2>/dev/null || true
                tc qdisc add dev "$iface" root handle 1: htb default 20 r2q 1000
                tc class add dev "$iface" parent 1: classid 1:1 htb rate ${outerLinkRate} ceil ${outerLinkRate}
                tc class add dev "$iface" parent 1:1 classid 1:10 htb rate ${vpnUploadCapRate} ceil ${vpnUploadCapRate}
                tc class add dev "$iface" parent 1:1 classid 1:20 htb rate ${outerLinkRate} ceil ${outerLinkRate}
                tc qdisc add dev "$iface" parent 1:10 handle 10: cake bandwidth ${vpnUploadCapRate} besteffort wash
                tc qdisc add dev "$iface" parent 1:20 handle 20: fq_codel
                tc filter add dev "$iface" protocol ip parent 1: prio 10 flower ip_proto udp src_port ${toString wgListenPort} classid 1:10
                tc filter add dev "$iface" protocol ipv6 parent 1: prio 11 flower ip_proto udp src_port ${toString wgListenPort} classid 1:10
                ;;
              stop)
                tc qdisc del dev "$iface" root 2>/dev/null || true
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
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe wgQosScript} start";
        ExecStop = "${lib.getExe wgQosScript} stop";
      };
  };
}
