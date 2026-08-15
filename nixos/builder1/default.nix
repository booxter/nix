{
  host.nix.builder = { };
  host.network.macAddress = "bc:24:11:49:bf:fc";
  host.proxmox.guest = {
    cluster = "lab";
    cores = 24;
    memoryGiB = 64;
    balloonGiB = 48;
    diskGiB = 150;
  };
  host.ups.client.server = "prx1-lab";
  system.stateVersion = "25.11";
}
