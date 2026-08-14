{ config, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./netboot.nix
  ];

  hardware.cpu.amd.updateMicrocode = true;

  host.realm = "home";
  host.disko.layout = "plain";
  host.proxmox = {
    cluster = "lab";
    node.enable = true;
  };
  host.network = {
    interfaces.enp5s0f0np0.kind = "ethernet";
    primaryInterface = "enp5s0f0np0";
  };
  host.proxmox.apiCertificate.serverName = "proxmox.${config.host.network.lanDomain}";
  host.proxmox.controller.enable = true;
  host.ups = {
    server = {
      description = "APC UPS 1500VA";
      waitForLowBattery = true;
    };
  };
}
