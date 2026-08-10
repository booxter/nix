{ ... }:
{
  system.stateVersion = "25.11";

  host.network = {
    interfaces.ens18.kind = "ethernet";
    macAddress = "bc:24:11:91:b5:77";
    primaryInterface = "ens18";
    reservation = {
      enable = true;
      address = "192.168.20.3";
    };
  };

}
