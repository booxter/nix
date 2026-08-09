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
    publicKeys = inventory.public-keys;
  };
}
