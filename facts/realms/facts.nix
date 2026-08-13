{ lib }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
  sshPublicKey = name: readPublicKey (../../common/_mixins/ssh/public-keys + "/${name}.pub");
in
{
  home = {
    build = {
      sshIdentityFile = "id_ed25519";
    };
    management = {
      manageNetworkIdentity = true;
      sudoWheelNeedsPassword = false;
    };
    trust.ssh = {
      authorizedKeys = [
        (sshPublicKey "mmini")
        (sshPublicKey "mair")
        (sshPublicKey "frame")
        (sshPublicKey "yubikey")
        (sshPublicKey "mair-secretive")
      ];
      fleetBootHosts = true;
      tickets.trustedCaPublicKeys = [
        (sshPublicKey "fleet-user-ca")
        (sshPublicKey "yubikey")
      ];
    };
  };

  work = {
    build = {
      sshIdentityFile = "jgwxhwdl4x-nix-builder";
    };
    management = {
      manageNetworkIdentity = false;
      sudoWheelNeedsPassword = true;
    };
    trust.ssh.authorizedKeys = [
      (sshPublicKey "jgwxhwdl4x")
      (sshPublicKey "jgwxhwdl4x-nix-builder")
    ];
  };
}
