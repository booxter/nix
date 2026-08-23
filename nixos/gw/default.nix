{ config, lib, ... }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.network.interfaces.ens18 = { };

  host.proxmox.guest = {
    cores = 2;
    memoryGiB = 8;
    diskGiB = 64;
  };

  host.wireguard.server = {
    network = "home";
    cidr = "10.83.0.0/24";
    address = "10.83.0.1";
    listenPort = 51820;
    publicEndpoint = "wg.${config.host.network.publicDomain}";
    publicKey = readPublicKey ./wireguard.pub;
    clientPolicy = {
      allowedIPs = [
        "10.83.0.0/24"
        config.host.site.lan.cidr
      ];
      dns = [
        config.host.site.lan.gateway.address
        config.host.network.lanDomain
      ];
    };
    dynamicDns = {
      hostname = "ihrachyshka-gw.freeddns.org";
      username = "ihrachyshka";
    };
    qos.uploadLimitMbit = 10;
    externalPeers.unifi-travel-router = {
      address = "10.83.0.20";
      publicKey = readPublicKey ./wireguard-peers/unifi-travel-router.pub;
    };
  };

}
