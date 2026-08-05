{
  imports = [
    (import ../disko { })
    ./netboot.nix
    ./ups.nix
  ];

  host.isProxmox = true;
}
