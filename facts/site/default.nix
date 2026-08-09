{
  context,
  factsModuleName,
  facts,
  factsLib,
  lib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix {
    inherit (context) lanDomain publicDomain;
    nixCaches = facts.nix-caches;
    publicKeys = facts.public-keys;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    inherit (context) lanDnsRecordTtlSeconds lanDomain;
    hosts = facts.hosts;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
