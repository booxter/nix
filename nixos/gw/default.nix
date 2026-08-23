{ ... }:
{
  system.stateVersion = "25.11";

  host.network.interfaces.ens18 = { };

  host.proxmox.guest = {
    cores = 2;
    memoryGiB = 8;
    diskGiB = 64;
  };

}
