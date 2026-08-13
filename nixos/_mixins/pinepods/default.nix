{ config, lib, ... }:
let
  cfg = config.host.pinepods;
in
{
  imports = [
    ./account.nix
    ./assertions.nix
    ./auth.nix
    ./backups.nix
    ./bootstrap.nix
    ./cache.nix
    ./container.nix
    ./database.nix
    ./options.nix
    ./storage.nix
    ./web.nix
  ];

  config = lib.mkIf cfg.enable {
    host.web.services.pinepods.enable = true;
  };
}
