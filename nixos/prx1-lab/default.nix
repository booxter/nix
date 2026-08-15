{ config, ... }:
{
  system.stateVersion = "25.11";

  imports = [
    ./netboot.nix
  ];

  hardware.cpu.amd.updateMicrocode = true;

  host.realm = "home";
  host.disko.layout = "plain";
  host.proxmox.node = {
    apiServerName = "proxmox.${config.host.network.lanDomain}";
    cluster = "lab";
    controller = { };
  };
  host.network.interfaces.enp5s0f0np0 = { };
  host.ups = {
    server = {
      description = "APC UPS 1500VA";
      waitForLowBattery = true;
    };
  };
}
