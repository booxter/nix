{
  lib,
  pkgs,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
  pkiPkgs = import ./pkgs pkgs;
in
{
  system.stateVersion = "25.11";

  _module.args = { inherit pkiPkgs; };

  imports = [
    ./uptimerobot-sync.nix
  ];

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
  };

  host.pki = {
    role = "authority";
    authority = {
      displayName = "Home Internal PKI";
      rootCaCertificate = ./root-ca.crt;
    };
  };

  host.sso.role = "provider";

  host.network = {
    macAddress = "bc:24:11:c6:ab:fc";
    reservation = {
      enable = true;
      address = "192.168.20.5";
    };
    ipController = {
      enable = true;
      flavor = "unifi";
      target = {
        endpoint = "https://unifi";
        site = "default";
      };
    };
  };

  host.ups.client.server = "prx1-lab";

}
