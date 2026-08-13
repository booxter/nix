{ config, lib, ... }:
{
  imports = [
    ./account.nix
    ./assertions.nix
    ./downloads.nix
    ./metrics.nix
    ./options.nix
    ./secrets.nix
    ./service.nix
    ./storage.nix
    ./vpn.nix
    ./web.nix
  ];

  config = lib.mkIf config.host.sabnzbd.enable {
    host.web.services.sabnzbd.enable = true;
  };
}
