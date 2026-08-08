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

  environment.systemPackages = with pkgs; [
    hdparm
    join-media-parts
    lm_sensors
    nvme-cli
  ];
}
