{
  config,
  fleetInventory,
  inputs,
  lib,
  outputs,
  ...
}:
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
  ];

  host.observability.inventory.machine = {
    hypervisor = config.host.proxmox.node != null;
    virtual = config.host.proxmox.guest != null;
  };

  _module.args.proxmoxModel = import ./model.nix {
    inherit
      config
      fleetInventory
      lib
      outputs
      ;
  };
}
