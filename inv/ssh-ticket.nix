{
  frame,
  mmini,
  readPublicKey,
}:
let
  secretivePublicKey = readPublicKey ../../public-keys/ssh-ca/fleet-user-ca.pub;
  yubikeyPublicKey = readPublicKey ../../public-keys/yubikey.pub;
  yubikeyIssuer = {
    publicKey = yubikeyPublicKey;
    keyName = "id_ed25519_sk_rk";
    useAgent = false;
  };
in
{
  trustedCaPublicKeys = [
    secretivePublicKey
    yubikeyPublicKey
  ];

  issuers = {
    mair = {
      publicKey = secretivePublicKey;
      keyName = "fleet-user-ca.pub";
      useAgent = true;
    };
    ${frame} = yubikeyIssuer;
    ${mmini} = yubikeyIssuer;
  };
}
