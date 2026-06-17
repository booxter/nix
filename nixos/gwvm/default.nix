{
  config,
  lib,
  hostInventory,
  ...
}:
let
  wgHome = hostInventory.site.wireguard.home;
  wgInterface = "wg0";
  wgListenPort = wgHome.gateway.listenPort;
  wgAddress = wgHome.gateway.address;
  lanInterface = "ens18";
  vpnPeers = import ./wg-home-peers.nix { inherit hostInventory; };

  mkPeer = peer: {
    inherit (peer) publicKey;
    allowedIPs = [ peer.address ] ++ (peer.extraAllowedIPs or [ ]);
  };
in
{
  imports = [
    ./qos.nix
    ./wg-home-exporter.nix
  ];

  host.externalService.ddns = {
    enable = true;
    hostname = "ihrachyshka-gw.freeddns.org";
    username = "ihrachyshka";
  };

  assertions = [
    {
      assertion =
        let
          addresses = map (peer: peer.address) vpnPeers;
        in
        lib.length addresses == lib.length (lib.unique addresses);
      message = "WireGuard peers on ${config.networking.hostName} must use unique tunnel IP addresses.";
    }
  ];

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };

  networking = {
    firewall = {
      allowedUDPPorts = [ wgListenPort ];
      # WireGuard peers are already authenticated by key, so treat tunnel
      # traffic as trusted once it reaches the gateway.
      trustedInterfaces = [ wgInterface ];
    };

    nat = {
      enable = true;
      externalInterface = lanInterface;
      internalInterfaces = [ wgInterface ];
    };

    wireguard.interfaces.${wgInterface} = {
      ips = [ wgAddress ];
      listenPort = wgListenPort;
      privateKeyFile = "/var/lib/wireguard/${wgInterface}.key";
      generatePrivateKeyFile = true;
      peers = map mkPeer vpnPeers;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/wireguard 0700 root root -"
  ];
}
