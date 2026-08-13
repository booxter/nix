{ config, lib, ... }:
let
  cfg = config.host.seerr;
in
{
  imports = [
    ./assertions.nix
    ./backups.nix
    ./options.nix
    ./reconcile.nix
    ./service.nix
    ./web.nix
  ];

  config = lib.mkIf cfg.enable {
    host.web.services.seerr.enable = true;
  };
}
