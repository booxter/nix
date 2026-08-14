{ config, lib, ... }:
let
  cfg = config.host.shelfmark;
in
{
  imports = [
    ./assertions.nix
    ./auth.nix
    ./backups.nix
    ./ebook-converter
    ./integrations.nix
    ./options.nix
    ./service.nix
    ./storage.nix
    ./web.nix
  ];

  config = lib.mkIf (cfg != null) {
    host.web.services.shelfmark.enable = true;
  };
}
