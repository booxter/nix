{
  lib,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };

  host.proxmox = {
    cluster = "lab";
    guest = {
      enable = true;
      cores = 2;
      memoryGiB = 4;
      diskGiB = 50;
    };
  };

  host.sso.role = "provider";

  host.observability.uptimeRobot.controller.enable = true;

  host.network = {
    macAddress = "bc:24:11:c6:ab:fc";
    reservation = {
      enable = true;
      address = "192.168.20.5";
    };
    ipController = {
      enable = true;
      flavor = "unifi";
      target = {
        endpoint = "https://unifi";
        site = "default";
      };
    };
  };

  host.ups.client.server = "prx1-lab";

}
