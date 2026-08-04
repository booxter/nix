{ hostInventory, ... }:
let
  wgHome = hostInventory.site.wireguard.home;
in
{
  imports = [ ../_mixins/wireguard-qos ];

  # Keep WireGuard peer downloads from filling the constrained home uplink.
  host.wireguardQos = {
    enable = true;
    interface = "ens18";
    wireguardUnit = "wireguard-wg0.service";
    port = wgHome.gateway.listenPort;
    egressPort = "source";
    uploadRateMbit = 10;
  };
}
