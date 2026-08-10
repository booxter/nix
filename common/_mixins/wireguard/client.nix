{
  config,
  facts,
  isDarwin,
  lib,
  ...
}:
let
  cfg = config.host.wireguard.client;
  network = facts.site.wireguard.${cfg.network};
  peers = builtins.filter (peer: (peer.host or null) == config.networking.hostName) (
    builtins.attrValues network.peers
  );
  peer = builtins.head peers;
  privateKeySecret = "wireguard/${network.gateway.host}/privateKey";
in
{
  config = lib.mkIf (cfg.network != null) {
    sops.secrets.${privateKeySecret} = {
      owner = "root";
      group = if isDarwin then "wheel" else "root";
      mode = "0400";
    };

    networking.wg-quick.interfaces.${cfg.interface} = {
      inherit (cfg) autostart;
      address = [ peer.address ];
      inherit (network.client) dns;
      privateKeyFile = config.sops.secrets.${privateKeySecret}.path;

      peers = [
        {
          publicKey = network.gateway.publicKey;
          endpoint = "${network.gateway.publicEndpoint}:${toString network.gateway.listenPort}";
          inherit (network.client) allowedIPs persistentKeepalive;
        }
      ];
    };
  };
}
