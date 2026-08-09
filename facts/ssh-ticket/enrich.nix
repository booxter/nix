{
  facts,
  lib,
}:
raw:
let
  hosts = facts.hosts;
  realms = facts.realms;
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
      defaultTtl = "30m";
      maxTtl = "2h";
      caPublicKeyConfigured = enabled && ticketPolicy.trustedCaPublicKeys != [ ];
      trustedCaPublicKeys = if enabled then ticketPolicy.trustedCaPublicKeys else [ ];
    };
  targets =
    lib.mapAttrsToList (_: mkTarget "nixos") hosts.nixos
    ++ lib.mapAttrsToList (_: mkTarget "darwin") hosts.darwin;
in
raw
// {
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
}
