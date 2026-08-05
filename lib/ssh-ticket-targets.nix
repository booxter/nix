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
      sshHost ? name,
      dnsName ? sshHost,
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
        sshHost
        ;
      aliases = lib.unique ([ name ] ++ aliases);
      inherit allowX11Forwarding;
      principal = if enabled then "${username}@${dnsName}" else "";
      defaultTtl = "30m";
      maxTtl = "2h";
      caPublicKeyConfigured = enabled && hasCaPublicKeys;
    };

  mkDarwinTarget =
    name: spec:
    let
      sshHost = spec.name;
    in
    mkTarget {
      kind = "darwin";
      inherit name;
      aliases = [
        sshHost
        (hostInventory.toLocalDnsName sshHost)
        (spec.dnsName or sshHost)
      ];
      dnsName = spec.dnsName or sshHost;
      allowX11Forwarding = spec.sshTicket.allowX11Forwarding or false;
      isWork = spec.isWork or false;
    };

  mkNixosTarget =
    spec:
    let
      localSshHost = hostInventory.toLocalDnsName spec.name;
      dnsName = spec.dnsName or spec.name;
    in
    mkTarget {
      kind = "nixos";
      name = spec.name;
      aliases = [
        spec.name
        localSshHost
        dnsName
      ];
      inherit dnsName;
      allowX11Forwarding = spec.sshTicket.allowX11Forwarding or false;
      isWork = spec.isWork or false;
    };
in
map mkNixosTarget hostInventory.nixosHostSpecs
++ lib.mapAttrsToList mkDarwinTarget hostInventory.darwinHosts
