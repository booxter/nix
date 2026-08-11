{
  system.stateVersion = "25.11";

  host.isProxmox = true;
  host.network = {
    interfaces.enp5s0f0np0.kind = "ethernet";
    macAddress = "38:05:25:30:7d:69";
    primaryInterface = "enp5s0f0np0";
    reservation = {
      enable = true;
      address = "192.168.15.12";
    };
  };
  host.ups.client.server = "prx1-lab";
}
