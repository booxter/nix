{
  imports = [
    ./netboot.nix
    ./ups.nix
  ];

  host.isProxmox = true;
}
