{ config, lib, ... }:
{
  imports = [
    ./assertions.nix
    ./backups.nix
    ./downloads.nix
    ./dynamic-ip-updater.nix
    ./options.nix
    ./service.nix
    ./storage.nix
    ./torrent-cleaner.nix
    ./tracker-policy.nix
    ./vpn.nix
    ./web.nix
  ];

  config = lib.mkIf config.host.transmission.enable {
    host.web.services.transmission.enable = true;
  };
}
