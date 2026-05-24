{
  hostInventory,
  lib,
  outputs,
  pkgs,
  wgConservativeUploadRateMbit,
  ...
}:
let
  srvarrSpec = hostInventory.nixosHostSpecsByName.srvarr;
  beastNfsAddress = hostInventory.dhcpReservationsByHostname.beast.ip;
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastJellyfinEndpoint = beastHostConfig.host.observability.client.prometheusMtlsEndpoints.jellyfin;
  beastNfsPort = hostInventory.site.ports.nfs;
  beastNfsRate = "1500mbit";
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  wgBridgeAddress = srvarrSpec.wgNamespace.bridgeAddress;
  wgNamespaceAddress = srvarrSpec.wgNamespace.namespaceAddress;
  wgConservativeUploadRate = "${toString wgConservativeUploadRateMbit}mbit";
  wgConservativeDownloadRate = "400mbit";
  wgEndpointPort = 1637;
  wgOuterLinkRate = "10gbit";
  wgUnitDepsBase = networkOnlineUnitDeps // {
    After = networkOnlineUnitDeps.After ++ [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgTimerDeps = {
    After = [ "wg.service" ];
  };
in
{
  boot.kernelModules = [ "ifb" ];

  imports = [
    (import ./adaptive-upload-policy.nix {
      jellyfinExporterUrl =
        "https://${beastHostConfig.host.dnsName}:${toString beastJellyfinEndpoint.port}${beastJellyfinEndpoint.path}";
      fallbackUploadRateMbit = wgConservativeUploadRateMbit;
      inherit
        networkOnlineUnitDeps
        wgEndpointPort
        wgOuterLinkRate
        wgUnitDepsBase
        ;
    })
    (import ./update-dynamic-ip.nix {
      inherit
        lib
        pkgs
        wgTimerDeps
        wgUnitDepsBase
        ;
    })
  ];

  host.observability.lanWan = {
    interface = "ens18";
    # nft postrouting overcounts the WireGuard transport on this host, so use
    # the shaped tc class as the authoritative WAN egress counter instead.
    wanTransmitTcClass = "1:10";
    wanUdpSubclass = {
      name = "wg";
      port = wgEndpointPort;
    };
  };

  nixarr.vpn = {
    enable = true;
    wgConf = "/data/.secret/vpn/wg.conf";
    accessibleFrom = [
      hostInventory.site.lan.cidr
      "10.0.0.0/8"
    ];
  };

  # Move VPN bridge off the lab subnet to avoid routing conflicts.
  vpnNamespaces.wg = {
    bridgeAddress = wgBridgeAddress;
    namespaceAddress = wgNamespaceAddress;
  };

  # Apply a conservative bidirectional shaping baseline on the outer interface
  # for WireGuard transport traffic. Also keep NFS writes to beast below the
  # unstable single-flow ceiling observed on this path.
  # The adaptive Jellyfin-aware controller can still raise the WireGuard upload
  # ceiling at runtime when the uplink is otherwise idle.
  systemd.services.wg-qos-upload = {
    wantedBy = [ "multi-user.target" ];
    unitConfig = wgUnitDepsBase;
    serviceConfig =
      let
        wgQosScript = pkgs.writeShellApplication {
          name = "wg-qos-upload";
          runtimeInputs = [
            pkgs.gawk
            pkgs.iproute2
            pkgs.kmod
          ];
          text = ''
            set -euo pipefail

            iface="$(${pkgs.iproute2}/bin/ip -o route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
            ifb_iface="ifb-wg"
            if [ -z "$iface" ]; then
              echo "failed to determine default egress interface" >&2
              exit 1
            fi

            case "''${1:-start}" in
              start)
                ${pkgs.kmod}/bin/modprobe ifb
                ${pkgs.iproute2}/bin/ip link add "$ifb_iface" type ifb 2>/dev/null || true
                ${pkgs.iproute2}/bin/ip link set dev "$ifb_iface" up

                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" root handle 1: htb default 20 r2q 1000
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1: classid 1:1 htb rate ${wgOuterLinkRate} ceil ${wgOuterLinkRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:10 htb rate ${wgConservativeUploadRate} ceil ${wgConservativeUploadRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:15 htb rate ${beastNfsRate} ceil ${beastNfsRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:20 htb rate ${wgOuterLinkRate} ceil ${wgOuterLinkRate}
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:10 handle 10: cake bandwidth ${wgConservativeUploadRate} besteffort wash
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:15 handle 15: fq_codel
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:20 handle 20: fq_codel
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ip parent 1: prio 10 flower ip_proto udp dst_port ${toString wgEndpointPort} classid 1:10
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ipv6 parent 1: prio 11 flower ip_proto udp dst_port ${toString wgEndpointPort} classid 1:10
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ip parent 1: prio 15 flower ip_proto tcp dst_ip ${beastNfsAddress} dst_port ${toString beastNfsPort} classid 1:15

                ${pkgs.iproute2}/bin/tc qdisc del dev "$ifb_iface" root 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc add dev "$ifb_iface" root cake bandwidth ${wgConservativeDownloadRate} besteffort wash ingress

                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" ingress 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" handle ffff: ingress
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" parent ffff: protocol ip prio 10 flower ip_proto udp src_port ${toString wgEndpointPort} action mirred egress redirect dev "$ifb_iface"
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" parent ffff: protocol ipv6 prio 11 flower ip_proto udp src_port ${toString wgEndpointPort} action mirred egress redirect dev "$ifb_iface"
                ;;
              stop)
                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" ingress 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root || true
                ${pkgs.iproute2}/bin/tc qdisc del dev "$ifb_iface" root 2>/dev/null || true
                ${pkgs.iproute2}/bin/ip link set dev "$ifb_iface" down 2>/dev/null || true
                ${pkgs.iproute2}/bin/ip link delete dev "$ifb_iface" type ifb 2>/dev/null || true
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
