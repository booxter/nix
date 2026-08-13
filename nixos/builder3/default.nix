{
  host.nix.builder.enable = true;
  host.network.macAddress = "bc:24:11:2a:ee:d7";
  host.proxmox = {
    cluster = "default";
    guest = {
      enable = true;
      cores = 24;
      memoryGiB = 64;
      balloonGiB = 48;
      diskGiB = 150;
    };
  };
  host.ups.client.server = "prx1-lab";
  system.stateVersion = "25.11";
}
