{
  darwinHosts,
  frame,
  lib,
  mmini,
  nixosHostSpecs,
  readPublicKey,
  realms,
  username,
}:
let
  secretivePublicKey = readPublicKey ../public-keys/ssh-ca/fleet-user-ca.pub;
  yubikeyPublicKey = readPublicKey ../public-keys/yubikey.pub;
  yubikeyIssuer = {
    publicKey = yubikeyPublicKey;
    keyName = "id_ed25519_sk_rk";
    useAgent = false;
  };
  mkTarget =
    kind: spec:
    let
      inherit (spec) name realm;
      ticketPolicy = realms.${realm}.trust.ssh.tickets or null;
      enabled = ticketPolicy != null;
    in
    {
      inherit
        enabled
        kind
        name
        realm
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
      caPublicKeyConfigured = enabled && ticketPolicy.trustedCaPublicKeys != [ ];
      trustedCaPublicKeys = if enabled then ticketPolicy.trustedCaPublicKeys else [ ];
    };
  targets =
    map (mkTarget "nixos") nixosHostSpecs ++ lib.mapAttrsToList (_: mkTarget "darwin") darwinHosts;
in
{
  inherit targets;

  trustedCaPublicKeysByRealm = lib.mapAttrs (
    _: realm: (realm.trust.ssh.tickets or { trustedCaPublicKeys = [ ]; }).trustedCaPublicKeys
  ) realms;

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
