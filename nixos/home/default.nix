{ lib, ... }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "26.05";

  host.proxmox = {
    cluster = "lab";
    guest = {
      enable = true;
      cores = 4;
      memoryGiB = 8;
      diskGiB = 80;
    };
  };

  host.ups.client.server = "prx1-lab";

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };

  host.home-assistant.enable = true;
}
