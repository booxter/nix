{
  context,
  factLibraryName,
  inventory,
  inventoryLib,
  lib,
  readPublicKey,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix {
    inherit readPublicKey;
    inherit (context) lanDomain publicDomain;
    nixCaches = inventory.nix-caches;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    inherit (context) lanDnsRecordTtlSeconds lanDomain;
    hosts = inventory.hosts;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
