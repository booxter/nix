{ username, ... }:
{
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
