{ config, lib, ... }:
let
  cfg = config.host.audiobookshelf;
in
{
  imports = [
    ./assertions.nix
    ./auth.nix
    ./backups.nix
    ./options.nix
    ./reconcile.nix
    ./service.nix
    ./storage.nix
    ./web.nix
  ];

  config = lib.mkIf (cfg != null) {
    host.web.services.audiobookshelf.enable = true;
  };
}
