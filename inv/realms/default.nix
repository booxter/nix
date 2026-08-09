{
  context,
  factLibraryName,
  inventory,
  inventoryLib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix {
    inherit (context) lanDomain;
    nixCaches = inventory.nix-caches;
    publicCertificates = inventory.public-certificates;
    publicKeys = inventory.public-keys;
  };
}
