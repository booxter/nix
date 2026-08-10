{
  config,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
  network = config.host.wireguard.networks.${cfg.network} or null;
  peers = builtins.attrValues network.peers;
  mkPeer = peer: {
    inherit (peer) publicKey;
    allowedIPs = [ peer.address ] ++ (peer.extraAllowedIPs or [ ]);
  };
in
{
  config = lib.mkIf (cfg.enable && network != null) {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    host.network.stableAddress.requiredBy = [ "WireGuard server ${cfg.network}" ];

    networking = {
      firewall = {
        allowedUDPPorts = [ network.server.listenPort ];
        trustedInterfaces = [ cfg.interface ];
      };

      nat = {
        enable = true;
        externalInterface = config.host.network.primaryInterface;
        internalInterfaces = [ cfg.interface ];
      };

      wireguard.interfaces.${cfg.interface} = {
        ips = [ network.server.address ];
        inherit (network.server) listenPort;
        privateKeyFile = "/var/lib/wireguard/${cfg.interface}.key";
        generatePrivateKeyFile = true;
        peers = map mkPeer peers;
      };
    };

    systemd.tmpfiles.rules = [ "d /var/lib/wireguard 0700 root root -" ];
  };
}
