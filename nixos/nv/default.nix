{ config, ... }:
let
  username = config.host.username;
in
{
  system.stateVersion = "25.11";

  host.network.macAddress = "bc:24:11:ed:30:d3";
  host.network.interfaces.ens18 = { };
  host.realm = "work";
  host.nix.builderClient = { };
  host.proxmox.guest = {
    cores = 64;
    memoryGiB = 128;
  };

  # Serve the single-use GlobalProtect browser login on the trusted work LAN.
  networking.firewall.interfaces.${config.host.network.primaryInterface}.allowedTCPPorts = [ 38080 ];

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
