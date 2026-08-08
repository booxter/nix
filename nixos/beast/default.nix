{
  pkgs,
  ...
}:
{
  imports = [
    ./backup-client.nix
    ./backup-server.nix
    ./jellyfin
    ./lolek.nix
  ];

  host.ups.scheduler.critical = true;

  networking.resolvconf.enable = true;

  environment.systemPackages = with pkgs; [
    hdparm
    join-media-parts
    lm_sensors
    nvme-cli
  ];
}
