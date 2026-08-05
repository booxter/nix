{
  hostInventory,
  lib,
  username ? "ihrachyshka",
}:
let
  hasCaPublicKeys = hostInventory.sshTicket.trustedCaPublicKeys != [ ];

  mkTarget =
    {
      kind,
      name,
      aliases ? [ name ],
      allowX11Forwarding ? false,
      isWork ? false,
    }:
    let
      enabled = !isWork;
    in
    {
      inherit
        enabled
        kind
        name
        ;
      sshHost = name;
      aliases = lib.unique ([ name ] ++ aliases);
      inherit allowX11Forwarding;
      principal = if enabled then "${username}@${name}" else "";
      defaultTtl = "30m";
      maxTtl = "2h";
      caPublicKeyConfigured = enabled && hasCaPublicKeys;
    };

  mkDarwinTarget =
    name: spec:
    mkTarget {
      kind = "darwin";
      inherit name;
      aliases = [ (hostInventory.toLocalDnsName spec.name) ];
      allowX11Forwarding = spec.sshTicket.allowX11Forwarding or false;
      isWork = spec.isWork or false;
    };

  mkNixosTarget =
    spec:
    mkTarget {
      kind = "nixos";
      name = spec.name;
      aliases = [ (hostInventory.toLocalDnsName spec.name) ];
      allowX11Forwarding = spec.sshTicket.allowX11Forwarding or false;
      isWork = spec.isWork or false;
    };
in
map mkNixosTarget hostInventory.nixosHostSpecs
++ lib.mapAttrsToList mkDarwinTarget hostInventory.darwinHosts
