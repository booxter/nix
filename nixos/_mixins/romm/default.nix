{ config, lib, ... }:
{
  imports = [
    ./account.nix
    ./assertions.nix
    ./assets.nix
    ./auth.nix
    ./backups.nix
    ./cache.nix
    ./containers.nix
    ./database.nix
    ./options.nix
    ./secrets.nix
    ./setup.nix
    ./storage.nix
    ./web.nix
  ];

  config = lib.mkIf config.host.romm.enable {
    host.web.services.romm.enable = true;
  };
}
