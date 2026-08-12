{ facts, ... }:
{
  system.stateVersion = "26.05";

  host.network = {
    macAddress = "02:48:4f:4d:45:01";
    reservation = {
      enable = true;
      address = "192.168.20.6";
    };
  };

  host.ups.client.server = "prx1-lab";

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = facts.public-keys.restic.home;
  };

  host.home-assistant.enable = true;
}
