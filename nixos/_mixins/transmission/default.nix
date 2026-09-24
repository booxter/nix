{ config, pkgs, ... }:
let
  transmissionModel = import ./model.nix { inherit config; };
in
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

  config._module.args = {
    inherit transmissionModel;
    transmissionPolicyFile =
      (pkgs.formats.json { }).generate "transmission-torrent-policy.json"
        transmissionModel.torrentPolicyDocument;
  };
}
