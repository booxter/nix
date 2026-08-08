{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.wireguardEndpoint;
  endpoint = hostInventory.site.wireguard.${cfg.name};
  listenPort = endpoint.gateway.listenPort;
  peers = lib.mapAttrsToList (name: peer: peer // { inherit name; }) endpoint.peers;
  mkPeer = peer: {
    inherit (peer) publicKey;
    allowedIPs = [ peer.address ] ++ (peer.extraAllowedIPs or [ ]);
  };
in
{
  config = lib.mkIf (cfg.name != null) {
    assertions = [
      {
        assertion = config.host.network.primaryInterface != null;
        message = "WireGuard endpoint ${cfg.name} requires a primary network interface";
      }
      {
        assertion =
          let
            addresses = map (peer: peer.address) peers;
          in
          builtins.length addresses == builtins.length (lib.unique addresses);
        message = "WireGuard endpoint ${cfg.name} peers must use unique tunnel addresses";
      }
    ];

    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    networking = {
      firewall = {
        allowedUDPPorts = [ listenPort ];
        # WireGuard peers are authenticated by key, so tunnel traffic can be
        # trusted after it reaches the endpoint interface.
        trustedInterfaces = [ cfg.interface ];
      };

      nat = {
        enable = true;
        externalInterface = config.host.network.primaryInterface;
        internalInterfaces = [ cfg.interface ];
      };

      wireguard.interfaces.${cfg.interface} = {
        ips = [ endpoint.gateway.address ];
        inherit listenPort;
        privateKeyFile = "/var/lib/wireguard/${cfg.interface}.key";
        # TODO: manage this durable endpoint identity through SOPS. The gateway
        # is not backed up, so regenerating the key would invalidate clients.
        generatePrivateKeyFile = true;
        peers = map mkPeer peers;
      };
    };

    systemd.tmpfiles.rules = [ "d /var/lib/wireguard 0700 root root -" ];
  };
}
