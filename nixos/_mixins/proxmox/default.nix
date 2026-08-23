{
  config,
  fleetInventory,
  inputs,
  ...
}:
let
  topology = import ./topology.nix {
    inherit config fleetInventory;
  };
in
{
  imports = [
    ./api-certificate.nix
    ./controller.nix
    ./guest.nix
    ./node.nix
    ./oidc.nix
    ./options.nix
    ./prometheus-exporter.nix
    inputs.proxmox-nixos.nixosModules.declarative-vms
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

  host.observability.inventory.machine = {
    hypervisor = config.host.proxmox.node != null;
    virtual = config.host.proxmox.guest != null;
  };

  _module.args.proxmoxTopology = topology;
}
