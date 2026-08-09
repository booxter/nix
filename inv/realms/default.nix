{
  context,
  factLibraryName,
  inventory,
  inventoryLib,
  readPublicKey,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix {
    inherit readPublicKey;
    inherit (context) lanDomain;
    nixCaches = inventory.nix-caches;
  };
}
