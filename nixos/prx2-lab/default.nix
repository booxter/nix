{
  system.stateVersion = "25.11";

  hardware.cpu.amd.updateMicrocode = true;

  host.realm = "home";
  host.disko.layout = "plain";
  host.proxmox.node = {
    cluster = "lab";
  };
  host.network.interfaces.enp5s0f0np0 = { };
  host.ups.client.server = "prx1-lab";
}
