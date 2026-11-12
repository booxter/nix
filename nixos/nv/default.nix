{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  authenticationPort = 38080;
  gpconnect = pkgs.callPackage ./pkgs/gpconnect {
    interface = config.host.network.primaryInterface;
    portalFile = config.sops.secrets."gpclient/portal".path;
    port = authenticationPort;
  };
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

  # The work laptop has no hardware SSH agent configured for sudo.
  security.sudo.wheelNeedsPassword = false;

  # Serve the single-use GlobalProtect browser login on the trusted work LAN.
  networking.firewall.interfaces.${config.host.network.primaryInterface}.allowedTCPPorts = [
    authenticationPort
  ];

  environment.systemPackages = [ gpconnect ];
  sops.secrets."gpclient/portal" = { };
  # The repository's sops bootstrap encrypts nv secrets to its SSH host key.
  sops.age = {
    keyFile = lib.mkForce null;
    generateKey = lib.mkForce false;
    sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

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
