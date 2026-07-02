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
      localSshHost = hostInventory.toLocalDnsName (hostInventory.toNixosShortDnsName spec);
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
        allowX11Forwarding = spec.sshTicket.allowX11Forwarding or false;
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
        allowX11Forwarding = spec.sshTicket.allowX11Forwarding or false;
        isWork = spec.isWork or false;
      };
in
map mkNixosTarget hostInventory.nixosHostSpecs
++ lib.mapAttrsToList mkDarwinTarget hostInventory.darwinHosts
