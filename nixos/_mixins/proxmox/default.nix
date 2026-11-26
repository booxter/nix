{
  config,
  fleetInventory,
  hostName,
  inputs,
  lib,
  ...
}:
let
  topology = import ./topology.nix {
    inherit fleetInventory hostName;
  };
in
{
  imports = [
    ./options.nix
  ]
  ++ lib.optionals topology.isGuest [
    ./guest.nix
    inputs.proxmox-nixos.nixosModules.declarative-vms
  ]
  ++ lib.optionals topology.isNode [
    ./api-certificate.nix
    ./memory-reclaim.nix
    ./node.nix
    ./oidc.nix
    ./prometheus-exporter.nix
    inputs.proxmox-nixos.nixosModules.proxmox-ve
  ];

  assertions = [
    {
      assertion = config.host.proxmox.node == null || config.host.proxmox.guest == null;
      message = "a host cannot be both a Proxmox node and guest";
    }
    {
      assertion = (config.host.proxmox.node != null) == topology.isNode;
      message = "local Proxmox node configuration and fleet topology must agree";
    }
    {
      assertion = (config.host.proxmox.guest != null) == topology.isGuest;
      message = "local Proxmox guest configuration and fleet topology must agree";
    }
  ];

  _module.args.proxmoxTopology = topology;
}
