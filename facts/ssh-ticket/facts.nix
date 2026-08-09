{
  context,
  facts,
}:
let
  inherit (context) frame mmini;
  publicKeys = facts.public-keys;
  yubikeyIssuer = {
    publicKey = publicKeys.users.yubikey;
    keyName = "id_ed25519_sk_rk";
    useAgent = false;
  };
in
{
  issuers = {
    mair = {
      publicKey = publicKeys.ssh-ca.fleet-user-ca;
      keyName = "fleet-user-ca.pub";
      useAgent = true;
    };
    ${frame} = yubikeyIssuer;
    ${mmini} = yubikeyIssuer;
  };
}
