{
  ...
}:
{
  system.stateVersion = "25.11";

  host.observability.server = { };

  host.proxmox.guest = {
    cores = 8;
    memoryGiB = 16;
    diskGiB = 300;
  };

}
