{
  lib,
  hostInventory,
  pkgs,
  ...
}:
let
  wgHome = hostInventory.site.wireguard.home;
  wgInterface = "wg0";
  wgExporterInternalAddress = "127.0.0.1";
  wgExporterInternalPort = 9587;
  wgExporterPublicAddress = hostInventory.toNixosHostIpv4Address wgHome.gateway.host;
  wgExporterPublicHost = "gw.${hostInventory.site.lan.domain}";
  wgExporterPublicPort = 9586;
  vpnPeers = import ./wg-home-peers.nix { inherit hostInventory; };

  wgExporterPeersFile = pkgs.writeText "wg-home-exporter-peers.json" (
    builtins.toJSON (
      map (peer: {
        inherit (peer)
          address
          name
          publicKey
          ;
      }) vpnPeers
    )
  );
in
{
  host.observability.client.prometheusMtlsEndpoints."wg-home" = {
    enable = true;
    listenAddress = wgExporterPublicAddress;
    port = wgExporterPublicPort;
    path = "/";
    upstream = "http://${wgExporterInternalAddress}:${toString wgExporterInternalPort}";
    serverName = wgExporterPublicHost;
    secretPrefix = "prometheus/wg-home";
  };

  systemd.services.wg-home-exporter = {
    description = "Expose home WireGuard peer status";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      "wireguard-${wgInterface}.service"
    ];
    after = [
      "network-online.target"
      "wireguard-${wgInterface}.service"
    ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.wg-home-exporter} --interface ${wgInterface} --listen-address ${wgExporterInternalAddress} --port ${toString wgExporterInternalPort} --handshake-max-age-seconds 180 --peers-json-file ${wgExporterPeersFile}";
      Restart = "on-failure";
      RestartSec = "10s";
      User = "root";
      Group = "root";
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectControlGroups = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };
}
