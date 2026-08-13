{ config, ... }:
let
  username = config.host.username;
in
{
  system.stateVersion = "25.11";

  host.network.macAddress = "bc:24:11:ed:30:d3";
  host.proxmox = {
    cluster = "default";
    guest = {
      enable = true;
      cores = 64;
      memoryGiB = 128;
    };
  };
  host.ups.client.server = "nvws";

  host.userEnvironment = {
    preset = "nvidia";
    roles.developer.enable = true;
  };
  host.user.passwords.sops.enable = false;

  # Work machines do not use sops-managed login passwords; this VM does not
  # currently configure a login password.
  security.sudo.wheelNeedsPassword = false;

  boot.kernelParams = [
    "default_hugepagesz=1GB"
    "hugepagesz=1G"
    "hugepages=8"
    "hugepagesz=2M"
    "hugepages=6000"
  ];

  virtualisation.docker.enable = true;
  users.users.${username}.extraGroups = [ "docker" ];
}
