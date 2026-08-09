{
  system.stateVersion = "25.11";

  host.isProxmox = true;
  host.network = {
    primaryInterface = "enp5s0f0np0";
    reservation = {
      enable = true;
      address = "192.168.15.11";
      identifiers = [ "38:05:25:30:7f:7d" ];
    };
  };
}
