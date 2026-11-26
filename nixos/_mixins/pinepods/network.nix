{ lib, pinepodsModel, ... }:
let
  inherit (pinepodsModel)
    cfg
    serviceAddress
    containerSubnet
    cachePort
    ollamaTunnelPort
    ;
  bridge = "podman-pinepods";
  backends = [
    "postgresql.service"
    "pinepods-valkey.service"
    "stunnel.service"
  ];
in
{
  config = lib.mkIf (cfg != null) {
    # Bind before Podman creates its bridge and keep listeners up when it disappears.
    # An address outside the container subnet makes clients route through the gateway.
    networking.interfaces.lo.ipv4.addresses = [
      {
        address = serviceAddress;
        prefixLength = 32;
      }
    ];
    systemd.services.network-addresses-lo = {
      before = backends;
      requiredBy = backends;
    };
    networking.firewall.interfaces.${bridge}.allowedTCPPorts = [
      5432
      cachePort
      ollamaTunnelPort
    ];

    environment.etc."containers/networks/pinepods.json".text = builtins.toJSON {
      name = "pinepods";
      id = builtins.hashString "sha256" "pinepods";
      driver = "bridge";
      network_interface = bridge;
      dns_enabled = true;
      subnets = [
        {
          subnet = containerSubnet;
          gateway = "10.89.42.1";
        }
      ];
      ipam_options.driver = "host-local";
    };
  };
}
