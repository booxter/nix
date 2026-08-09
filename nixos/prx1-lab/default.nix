{
  imports = [
    ./netboot.nix
    ./ups.nix
  ];

  host.isProxmox = true;
  host.network.primaryInterface = "enp5s0f0np0";
}
