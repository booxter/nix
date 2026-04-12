{ lib, ... }:
let
  wgInterface = "wg0";
  wgListenPort = 51820;
  wgAddress = "10.83.0.1/24";
  lanInterface = "ens18";

  vpnPeers = [
    # Add peers here after generating each client's public key, for example:
    # {
    #   name = "iphone";
    #   publicKey = "BASE64_PUBLIC_KEY";
    #   address = "10.83.0.10";
    # }
  ];

  mkPeer = peer: {
    inherit (peer) publicKey;
    allowedIPs = [ "${peer.address}/32" ] ++ (peer.extraAllowedIPs or [ ]);
  };
in
{
  assertions = [
    {
      assertion =
        let
          addresses = map (peer: peer.address) vpnPeers;
        in
        lib.length addresses == lib.length (lib.unique addresses);
      message = "WireGuard peers on prox-gwvm must use unique tunnel IP addresses.";
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
