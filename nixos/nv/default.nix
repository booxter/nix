{ config, ... }:
let
  username = config.host.username;
in
{
  system.stateVersion = "25.11";

  host.network.macAddress = "bc:24:11:ed:30:d3";

  host.userEnvironment = {
    roles.developer.enable = true;
    features.codex = {
      usageStatus.enable = false;
      resetCredits.enable = false;
      workUsageStatus.enable = true;
    };
  };

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
