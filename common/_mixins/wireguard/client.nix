{
  config,
  lib,
  system,
  ...
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  cfg = config.host.wireguard.client;
  network = config.host.wireguard.networks.${cfg.network} or null;
in
{
  config = lib.mkIf (cfg.enable && network != null) {
    sops.secrets.${cfg.privateKeySecret} = {
      owner = "root";
      group = if isDarwin then "wheel" else "root";
      mode = "0400";
    };

    networking.wg-quick.interfaces.${cfg.interface} = {
      inherit (cfg) autostart;
      address = [ "${cfg.address}/32" ];
      inherit (network.clientPolicy) dns;
      privateKeyFile = config.sops.secrets.${cfg.privateKeySecret}.path;

      peers = [
        {
          publicKey = network.server.publicKey;
          endpoint = "${network.server.publicEndpoint}:${toString network.server.listenPort}";
          inherit (network.clientPolicy) allowedIPs persistentKeepalive;
        }
      ];
    };
  };
}
