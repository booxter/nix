{ config, lib, ... }:
let
  cfg = config.host.shelfmark;
in
{
  imports = [
    ./assertions.nix
    ./auth.nix
    ./backups.nix
    ./integrations.nix
    ./options.nix
    ./service.nix
    ./storage.nix
    ./web.nix
  ];

  config = lib.mkIf cfg.enable {
    host.web.services.shelfmark.enable = true;
  };
}
