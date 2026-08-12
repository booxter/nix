{
  config,
  lib,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 6;

  imports = [
    ./opencode.nix
  ];

  host = {
    hardware.isLaptop = true;
    network.interfaces.en0.kind = "wireless";
    security = {
      secrets.operator.ageIdentity = {
        backend = "secure-enclave";
        path = "/Users/${config.host.username}/.config/sops/age/mair-se.txt";
      };
      ssh.credentials = {
        backend = "secretive";
        secretive.publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHMpzrKs1o9ek9+rZw3O8y7tzedq+iMObfvGA1xVS9uKX1cdSp7rnWyq83Y2hsfPI+J2quB42JFVUzCxn4NVfvM= ihar.hrachyshka@gmail.com";
      };
    };
    userEnvironment = {
      preset = "personal";
      roles = {
        developer.enable = true;
        workstation.enable = true;
      };
    };
    remote-control = {
      client = {
        enable = true;
        wayland.enable = true;
      };
      server.vnc.enable = true;
    };
    wireguard.client = {
      enable = true;
      network = "home";
      address = "10.83.0.10";
      publicKey = readPublicKey ./wireguard.pub;
      privateKeySecret = "wireguard/gw/privateKey";
    };
  };

}
