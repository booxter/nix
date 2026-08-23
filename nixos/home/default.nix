{ lib, ... }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "26.05";

  host.proxmox.guest = {
    cores = 4;
    memoryGiB = 8;
    diskGiB = 80;
  };

  host.backups.destination = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };

  host.home-assistant.enable = true;
}
