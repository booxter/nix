{ lib, ... }:
{
  system.stateVersion = "25.11";

  host = {
    ci.runners = 6;
    network.macAddress = "bc:24:11:7f:01:17";
    nix.builderClient = {
      buildUse = "ci";
    };
    proxmox.guest = {
      cores = 12;
      memoryGiB = 32;
      balloonGiB = 24;
      diskGiB = 300;
    };
  };

  nix.settings.max-jobs = lib.mkForce 0;
}
