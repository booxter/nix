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
  host.backups.sources.step-ca.paths = [ "/var/lib/step-ca" ];

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
      address = "192.168.20.5";
    };
    ipController = "unifi";
  };

  host.ups.client.server = "prx1-lab";

}
