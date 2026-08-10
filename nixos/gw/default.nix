{ facts, ... }:
{
  system.stateVersion = "25.11";

  host.network = {
    interfaces.ens18.kind = "ethernet";
    macAddress = "bc:24:11:91:b5:77";
    primaryInterface = "ens18";
    reservation = {
      enable = true;
      address = "192.168.20.3";
    };
  };

  host.wireguard.server = {
    enable = true;
    network = "home";
    interface = "wg0";
    cidr = "10.83.0.0/24";
    address = "10.83.0.1/24";
    listenPort = 51820;
    publicEndpoint = "wg.${facts.site.public.domain}";
    publicKey = facts.public-keys.wireguard.home-gateway;
    clientPolicy = {
      allowedIPs = [
        "10.83.0.0/24"
        facts.site.lan.cidr
      ];
      dns = [
        facts.site.lan.gateway.address
        facts.site.lan.domain
      ];
      persistentKeepalive = 25;
    };
    dynamicDns = {
      enable = true;
      hostname = "ihrachyshka-gw.freeddns.org";
      username = "ihrachyshka";
    };
    qos.uploadLimitMbit = 10;
    externalPeers.unifi-travel-router = {
      address = "10.83.0.20/32";
      publicKey = facts.public-keys.wireguard.home-unifi-travel-router;
    };
  };

}
