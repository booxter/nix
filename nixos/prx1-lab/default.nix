{
  imports = [
    (import ../disko { })
    ./netboot.nix
  ];

  host.isProxmox = true;
  host.ups.scheduler.critical = true;
}
