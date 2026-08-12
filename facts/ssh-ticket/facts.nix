{
  context,
  lib,
}:
let
  inherit (context) frame mmini;
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
  sshPublicKey = name: readPublicKey (../../common/_mixins/ssh/public-keys + "/${name}.pub");
  yubikeyIssuer = {
    publicKey = sshPublicKey "yubikey";
    keyName = "id_ed25519_sk_rk";
    useAgent = false;
  };
in
{
  issuers = {
    mair = {
      publicKey = sshPublicKey "fleet-user-ca";
      keyName = "fleet-user-ca.pub";
      useAgent = true;
    };
    ${frame} = yubikeyIssuer;
    ${mmini} = yubikeyIssuer;
  };
}
