{ config, lib, ... }:
let
  cfg = config.host.degoog;
in
{
  imports = [
    ./assertions.nix
    ./backups.nix
    ./extensions.nix
    ./integrations.nix
    ./options.nix
    ./secrets.nix
    ./service.nix
    ./web.nix
  ];

  config = lib.mkIf cfg.enable {
    host.web.services.goo.enable = true;
  };
}
