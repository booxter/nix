{
  lib,
  pkgs,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.network = {
    macAddress = "bc:24:11:fd:eb:9c";
    reservation = {
      enable = true;
      address = "192.168.20.4";
    };
  };

  host.ups.client.server = "prx1-lab";

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
    # Preserve the existing repository namespace and snapshot history.
    storageName = "orgvm";
  };

  _module.args.orgPkgs = import ./pkgs pkgs;

  imports = [
    ./degoog.nix
    ./paperless.nix
  ];

  host.vikunja.enable = true;
}
