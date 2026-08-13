{ config, lib, ... }:
let
  cfg = config.host.houndarr;
in
{
  imports = [
    ./assertions.nix
    ./auth.nix
    ./backups.nix
    ./integrations.nix
    ./observability.nix
    ./options.nix
    ./reconcile.nix
    ./service.nix
    ./web.nix
  ];

  config = lib.mkIf cfg.enable {
    host.web.services.houndarr.enable = true;
  };
}
