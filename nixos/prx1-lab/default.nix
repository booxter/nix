{
  imports = [
    ./netboot.nix
  ];

  host.isProxmox = true;
  host.ups.scheduler.critical = true;
}
