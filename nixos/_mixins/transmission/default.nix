{ config, ... }:
{
  imports = [
    ./assertions.nix
    ./backups.nix
    ./downloads.nix
    ./dynamic-ip-updater.nix
    ./options.nix
    ./service.nix
    ./storage.nix
    ./torrent-cleaner.nix
    ./tracker-policy.nix
    ./vpn.nix
    ./web.nix
  ];

  config._module.args.transmissionModel = import ./model.nix { inherit config; };
}
