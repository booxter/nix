{
  system.stateVersion = "25.11";

  hardware.cpu.amd.updateMicrocode = true;

  host.realm = "home";
  host.disko.layout = "plain";
  host.proxmox = {
    cluster = "lab";
    node.enable = true;
  };
  host.network = {
    interfaces.enp5s0f0np0.kind = "ethernet";
    macAddress = "38:05:25:30:7f:7d";
    primaryInterface = "enp5s0f0np0";
    reservation = {
      address = "192.168.15.11";
    };
  };
  host.ups.client.server = "prx1-lab";
}
