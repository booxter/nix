{ config, lib, ... }:
let
  readPublicKey = import ../../_lib/read-public-key.nix { inherit lib; };
in
lib.mkIf (config.host.realm == "home") {
  host.ssh.preBoot.endpoints = {
    frame-boot = {
      hostName = "frame";
      publicHostKey = readPublicKey ../../../nixos/frame/initrd_ssh_host_ed25519_key.pub;
      user = "root";
      authentication = "public-key";
      requestTTY = true;
    };
    mmini-boot = {
      hostName = "mmini";
      hostKeyAlias = "mmini";
      authentication = "password";
    };
  };
}
