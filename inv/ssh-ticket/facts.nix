{
  frame,
  mmini,
  readPublicKey,
}:
let
  yubikeyIssuer = {
    publicKey = readPublicKey ../../public-keys/yubikey.pub;
    keyName = "id_ed25519_sk_rk";
    useAgent = false;
  };
in
{
  issuers = {
    mair = {
      publicKey = readPublicKey ../../public-keys/ssh-ca/fleet-user-ca.pub;
      keyName = "fleet-user-ca.pub";
      useAgent = true;
    };
    ${frame} = yubikeyIssuer;
    ${mmini} = yubikeyIssuer;
  };
}
