{
  lib,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.backups.destination = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };
  host.backups.sources.step-ca.paths = [ "/var/lib/step-ca" ];

  host.proxmox.guest = {
    cluster = "lab";
    cores = 2;
    memoryGiB = 4;
    diskGiB = 50;
  };

  host.sso.provider.enable = true;

  host.observability.uptimeRobot.controller.enable = true;

  host.network.ipController.enable = true;

  host.ups.client.server = "prx1-lab";

}
