{
  config,
  facts,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.server;
  network = facts.site.wireguard.${cfg.network};
  peers = builtins.attrValues network.peers;
  mkPeer = peer: {
    inherit (peer) publicKey;
    allowedIPs = [ peer.address ] ++ (peer.extraAllowedIPs or [ ]);
  };
in
{
  config = lib.mkIf (cfg.network != null) {
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    host.network.stableAddress.requiredBy = [ "WireGuard server ${cfg.network}" ];

    networking = {
      firewall = {
        allowedUDPPorts = [ network.gateway.listenPort ];
        trustedInterfaces = [ cfg.interface ];
      };

      nat = {
        enable = true;
        externalInterface = config.host.network.primaryInterface;
        internalInterfaces = [ cfg.interface ];
      };

      wireguard.interfaces.${cfg.interface} = {
        ips = [ network.gateway.address ];
        inherit (network.gateway) listenPort;
        privateKeyFile = "/var/lib/wireguard/${cfg.interface}.key";
        generatePrivateKeyFile = true;
        peers = map mkPeer peers;
      };
    };

    systemd.tmpfiles.rules = [ "d /var/lib/wireguard 0700 root root -" ];
  };
}
