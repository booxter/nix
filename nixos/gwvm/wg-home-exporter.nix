{
  lib,
  hostInventory,
  pkgs,
  ...
}:
let
  wgHome = hostInventory.site.wireguard.home;
  wgInterface = "wg0";
  wgExporterListenAddress = hostInventory.toNixosHostIpv4Address wgHome.gateway.host;
  wgExporterPort = 9586;
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
  networking.firewall.allowedTCPPorts = [ wgExporterPort ];

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
      ExecStart = "${lib.getExe pkgs.wg-home-exporter} --interface ${wgInterface} --listen-address ${wgExporterListenAddress} --port ${toString wgExporterPort} --handshake-max-age-seconds 180 --peers-json-file ${wgExporterPeersFile}";
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
