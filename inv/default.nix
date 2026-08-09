{ lib }:
let
  inventoryLib = import ./lib.nix { inherit lib; };
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  context = {
    lanDnsRecordTtlSeconds = 300;
    lanDomain = "home.arpa";
    publicDomain = "ihar.dev";
    frame = "frame";
    mmini = "mmini";
  };
  call = path: args: import path ({ inherit inventoryLib; } // args);

  accounts = call ./accounts { inherit lib; };
  mediaLibraries = call ./media-libraries { };
  nixCaches = call ./nix-caches { inherit context readPublicKey; };
  realms = call ./realms { inherit context nixCaches readPublicKey; };
  hosts = call ./hosts { inherit context lib realms; };
  sharedStorage = call ./shared-storage {
    inherit
      accounts
      lib
      mediaLibraries
      ;
  };
  nfs = call ./nfs {
    inherit
      accounts
      lib
      sharedStorage
      ;
  };
  backups = call ./backups { inherit lib readPublicKey; };
  observability = call ./observability { };
  sites = call ./sites { };
  site = call ./site {
    inherit
      context
      hosts
      lib
      nixCaches
      readPublicKey
      ;
  };
  sshTicket = call ./ssh-ticket {
    inherit
      context
      hosts
      lib
      readPublicKey
      realms
      ;
  };
  sso = call ./sso { };
  ups = call ./ups { };
  yubi = call ./yubi { inherit context; };
in
{
  inherit
    accounts
    backups
    mediaLibraries
    nfs
    observability
    realms
    sharedStorage
    site
    sites
    sshTicket
    sso
    ups
    yubi
    ;
  inherit (context) lanDomain;
  inherit (hosts)
    darwinHosts
    dhcpReservationsByHostname
    hostSpecsByName
    managedDhcpReservations
    nixosHosts
    nixosHostSpecs
    secretDomainsByHost
    staticDhcpReservations
    systemsByHost
    toHostIpv4Address
    toLocalDnsName
    toNixosHostCertificateDnsNames
    toNixosHostIpv4Address
    toSshKnownHostNames
    toUpsName
    ;
}
