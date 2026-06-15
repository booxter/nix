{
  hostInventory,
  lib,
  username ? "ihrachyshka",
}:
let
  hasCaPublicKey = hostInventory.sshTicket.userCaPublicKey != null;

  mkTarget =
    {
      kind,
      name,
      sshHost ? name,
      dnsName ? sshHost,
      aliases ? [ name ],
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
      principal = if enabled then "${username}@${dnsName}" else "";
      defaultTtl = "30m";
      maxTtl = "2h";
      caPublicKeyConfigured = enabled && hasCaPublicKey;
    };

  mkDarwinTarget =
    name: spec:
    let
      sshHost = spec.hostname or name;
    in
    mkTarget {
      kind = "darwin";
      inherit name;
      aliases = [
        sshHost
        "${sshHost}.local"
        (spec.dnsName or sshHost)
      ];
      dnsName = spec.dnsName or sshHost;
      isWork = spec.isWork or false;
    };

  mkNixosTarget =
    spec:
    let
      localSshHost = "${hostInventory.toNixosShortDnsName spec}.local";
    in
    if hostInventory.isNixosVM spec then
      let
        sshHost = hostInventory.toNixosShortDnsName spec;
      in
      mkTarget {
        kind = "nixos";
        name = spec.name;
        inherit sshHost;
        aliases = [
          spec.name
          localSshHost
        ];
        isWork = spec.isWork or false;
      }
    else
      mkTarget {
        kind = "nixos";
        name = spec.name;
        aliases = [
          (spec.hostname or spec.name)
          localSshHost
          (spec.dnsName or (spec.hostname or spec.name))
        ];
        dnsName = spec.dnsName or (spec.hostname or spec.name);
        isWork = spec.isWork or false;
      };
in
map mkNixosTarget hostInventory.nixosHostSpecs
++ lib.mapAttrsToList mkDarwinTarget hostInventory.darwinHosts
