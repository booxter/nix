{ username, ... }:
{
  # TODO: revert once a password is set for this host (currently no hashedPassword is configured).
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
