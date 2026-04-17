{ config, ... }:
{
  sops.secrets."wireguard/gwvm/privateKey" = {
    owner = "root";
    group = "wheel";
    mode = "0400";
  };

  networking.wg-quick.interfaces.wg0 = {
    # Keep this as an on-demand tunnel on the laptop to avoid forcing it up on
    # every network. The interface is ready once deployed.
    autostart = false;
    address = [ "10.83.0.10/32" ];
    dns = [ "192.168.1.1" ];
    privateKeyFile = config.sops.secrets."wireguard/gwvm/privateKey".path;

    peers = [
      {
        publicKey = "ftjXEviy3flbMlXVntXs/QDcDUWR9f38nIPAcDTe4Gc=";
        endpoint = "wg.ihar.dev:51820";
        allowedIPs = [
          "10.83.0.0/24"
          "192.168.0.0/16"
        ];
        persistentKeepalive = 25;
      }
    ];
  };
}
