{
  context,
  factLibraryName,
  inventory,
  inventoryLib,
  lib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix {
    inherit (context) lanDomain publicDomain;
    nixCaches = inventory.nix-caches;
    publicKeys = inventory.public-keys;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    inherit (context) lanDnsRecordTtlSeconds lanDomain;
    hosts = inventory.hosts;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
