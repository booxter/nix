{
  host.nix.builder.maxJobs = 2;
  host.network.macAddress = "bc:24:11:2a:ee:d7";
  host.proxmox.guest = {
    cores = 24;
    memoryGiB = 64;
    balloonGiB = 48;
    diskGiB = 150;
  };
  system.stateVersion = "25.11";
}
