{
  darwinHosts,
  frame,
  lib,
  mmini,
  nixosHostSpecs,
  realms,
  ssh,
  username,
}:
let
  secretiveIdentity = ssh.userIdentities.fleetUserCa;
  yubikeyIdentity = ssh.userIdentities.yubikey;
  yubikeyIssuer = {
    inherit (yubikeyIdentity) publicKey;
    keyName = yubikeyIdentity.fileName;
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
      allowX11Forwarding = spec.remoteGui.server.x11.enable or false;
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
      inherit (secretiveIdentity) publicKey;
      keyName = secretiveIdentity.fileName;
      useAgent = true;
    };
    ${frame} = yubikeyIssuer;
    ${mmini} = yubikeyIssuer;
  };
}
