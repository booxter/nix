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

  host.pki.server = { };

  host.proxmox.guest = {
    cores = 2;
    memoryGiB = 8;
    diskGiB = 50;
  };

  host.sso.provider = { };

  host.observability.uptimeRobot.controller.enable = true;

  host.network.ipController = { };

}
