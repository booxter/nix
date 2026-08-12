{ config, lib, ... }:
let
  cfg = config.host.paperless;
in
{
  imports = [
    ./assertions.nix
    ./bootstrap.nix
    ./gpt.nix
    ./observability.nix
    ./options.nix
    ./secrets.nix
    ./service.nix
    ./sso.nix
    ./storage.nix
    ./web.nix
  ];

  config = lib.mkIf cfg.enable {
    host.web.services.paperless.enable = true;
  };
}
