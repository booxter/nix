{
  darwinHosts,
  frame,
  lib,
  mmini,
  nixosHostSpecs,
  readPublicKey,
  username,
}:
let
  secretivePublicKey = readPublicKey ../../public-keys/ssh-ca/fleet-user-ca.pub;
  yubikeyPublicKey = readPublicKey ../../public-keys/yubikey.pub;
  trustedCaPublicKeys = [
    secretivePublicKey
    yubikeyPublicKey
  ];
  yubikeyIssuer = {
    publicKey = yubikeyPublicKey;
    keyName = "id_ed25519_sk_rk";
    useAgent = false;
  };
  mkTarget =
    kind: spec:
    let
      inherit (spec) name;
      enabled = !(spec.isWork or false);
    in
    {
      inherit
        enabled
        kind
        name
        ;
      sshHost = name;
      aliases = [
        name
        "${name}.local"
      ];
      allowX11Forwarding = spec.sshTicket.allowX11Forwarding or false;
      principal = if enabled then "${username}@${name}" else "";
      defaultTtl = "30m";
      maxTtl = "2h";
      caPublicKeyConfigured = enabled && trustedCaPublicKeys != [ ];
    };
  targets =
    map (mkTarget "nixos") nixosHostSpecs ++ lib.mapAttrsToList (_: mkTarget "darwin") darwinHosts;
in
{
  inherit targets trustedCaPublicKeys;

  targetsByName = builtins.listToAttrs (
    map (target: {
      inherit (target) name;
      value = target;
    }) targets
  );

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
